import AppKit
import WebKit

@MainActor
private final class RemoteTabPageDelegate: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var finished = false
    var error: Error?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {}

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.error = error
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        self.error = error
    }
}

extension SessionTabTests {
    @MainActor
    static func testRemoteTabScrolling(html: String, baseURL: URL) async throws {
        for sidebar in [false, true] {
            try await testRemoteTabLayout(html: html, baseURL: baseURL, sidebar: sidebar)
        }
    }

    @MainActor
    private static func testRemoteTabLayout(html: String, baseURL: URL, sidebar: Bool) async throws {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let delegate = RemoteTabPageDelegate()
        if sidebar {
            configuration.userContentController.add(delegate, name: "cantripRemoteUnpair")
        }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 740, height: 500),
                                configuration: configuration)
        webView.navigationDelegate = delegate
        let window = NSWindow(contentRect: webView.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
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

        _ = try await webView.evaluateJavaScript("""
        window.check=(value,message)=>{if(!value)throw Error(message)};
        check(typeof renderSessions==="function","Remote script must load");
        check(sidebarLayout===\(sidebar ? "true" : "false"),"Only the native Mac embed uses the sidebar");
        pair(false);
        window.tabs=Array.from({length:32},(_,index)=>({
          id:`tab-${index}`,title:`Remote project ${index} with a long name`,
          customTitle:"",isLocked:index===2,supportsTabMetadata:true
        }));
        window.nav=$("sessions");
        window.offset=sidebarLayout?"scrollTop":"scrollLeft";
        window.visible=tab=>{
          const bounds=tab.getBoundingClientRect(),viewport=nav.getBoundingClientRect();
          const start=sidebarLayout?"top":"left",end=sidebarLayout?"bottom":"right",size=sidebarLayout?"height":"width";
          const overlap=Math.min(bounds[end],viewport[end])-Math.max(bounds[start],viewport[start]);
          return overlap>=Math.min(bounds[size],viewport[size])-1;
        };
        window.wheel=options=>{
          const event=new WheelEvent("wheel",{bubbles:true,cancelable:true,...options});
          nav.lastElementChild.children[0].dispatchEvent(event);
          return event;
        };
        void 0;
        """)

        for (width, height) in [(320, 340), (440, 500), (740, 340), (740, 700), (1100, 700)] {
            window.setContentSize(NSSize(width: width, height: height))
            webView.frame.size = NSSize(width: width, height: height)
            _ = try await webView.evaluateJavaScript("""
            (()=>{
            selected=null;renderSessions([]);selected=tabs[0].id;renderSessions(tabs);
            check(nav.children.length===32,"No tab count limit");
            if(sidebarLayout){
              check(nav.scrollHeight>nav.clientHeight&&nav.clientHeight>200,"Sidebar must scroll vertically within the window");
              check(nav.scrollWidth<=nav.clientWidth+1,"Sidebar titles wrap without horizontal overflow");
              const sidebar=$("sessionSidebar").getBoundingClientRect(),header=document.querySelector(".workspace").getBoundingClientRect();
              check(sidebar.left===0&&sidebar.top===0&&sidebar.bottom===innerHeight,"Expanded sidebar fills the left edge");
              check(header.left>=sidebar.right&&$("messages").getBoundingClientRect().left>=sidebar.right,"Sidebar must not overlap chat");
              check($("newSession").closest("#sessionSidebarHeader"),"New Tab lives in the sidebar");
              check(nav.children[1].getBoundingClientRect().top>=nav.children[0].getBoundingClientRect().bottom,"Tabs form a vertical list");
              for(const control of nav.querySelectorAll("button")){
                const bounds=control.getBoundingClientRect();
                check(bounds.width>0&&bounds.left>=sidebar.left&&bounds.right<=sidebar.right,"Row actions stay inside the sidebar");
              }
            }else{
              check(nav.scrollWidth>nav.clientWidth&&nav.clientWidth>60,"Browser tab strip must overflow inside the window");
              check(nav.closest(".tools")&&$("sessionSidebar").classList.contains("hidden"),"Browser keeps the original top strip");
            }
            check(document.documentElement.scrollWidth<=innerWidth+1,"Tabs must not widen the whole page");
            for(const id of ["newSession","draft","send","mode","forget"]){
              const bounds=$(id).getBoundingClientRect();
              check(bounds.left>=0&&bounds.right<=innerWidth+1,`${id} must remain reachable`);
            }
            check(nav.children[2].children[1].disabled,"Locked tabs cannot close");
            check(visible(nav.firstElementChild),"Initial selection must be visible");
            const horizontal=wheel({deltaX:80,deltaY:2});
            check(!horizontal.defaultPrevented,"Native horizontal trackpad scrolling stays native");
            check(!wheel({deltaY:80,ctrlKey:true}).defaultPrevented,"Pinch/zoom is not intercepted");
            check(!wheel({deltaY:80,shiftKey:true}).defaultPrevented,"Shift-wheel stays native");
            followOutput=true;
            if(sidebarLayout){
              check(!wheel({deltaY:80}).defaultPrevented&&!wheel({deltaY:-40}).defaultPrevented,"Sidebar retains native vertical wheel scrolling");
              nav.scrollTop=nav.scrollHeight;
            }else{
              check(wheel({deltaY:80}).defaultPrevented&&nav.scrollLeft>=79,"Mouse wheel scrolls the tabs");
              check(wheel({deltaY:-40}).defaultPrevented&&nav.scrollLeft<=41,"Reverse wheel scrolls back");
              const beforeLine=nav.scrollLeft;
              wheel({deltaY:2,deltaMode:1});
              check(Math.abs(nav.scrollLeft-beforeLine-32)<1,"Line-mode wheels use pixel distances");
              const beforePage=nav.scrollLeft;
              wheel({deltaY:1,deltaMode:2});
              check(Math.abs(nav.scrollLeft-beforePage-nav.clientWidth)<1,"Page-mode wheels use the strip width");
              for(let index=0;index<100;index++)wheel({deltaY:100});
            }
            check(followOutput,"Scrolling tabs must not disable transcript following");
            check(visible(nav.lastElementChild),"Scrolling must reach the final tab");
            window.lastButton=nav.lastElementChild.children[0];
            lastButton.focus();
            window.savedOffset=nav[offset];
            $("draft").value="Keep my unsent draft";
            for(let index=0;index<10;index++)renderSessions(tabs.map(tab=>({...tab})));
            check(nav.lastElementChild.children[0]===lastButton,"Polling must reuse existing tab controls");
            check(document.activeElement===lastButton,"Polling must retain keyboard focus");
            check(Math.abs(nav[offset]-savedOffset)<1,"Polling must not reset scrolling or snap to selection");
            check($("draft").value==="Keep my unsent draft","Polling preserves the draft");
            lastButton.click();renderSessions(tabs);
            check(selected===tabs[31].id&&visible(nav.lastElementChild),"Last tab must be selectable");
            check(lastButton.getAttribute("aria-current")==="true","Selection is accessible");
            nav[offset]=0;renderSessions(tabs);
            check(nav[offset]===0,"Browsing away from the selected tab survives refresh");
            selected=tabs[20].id;renderSessions(tabs);
            check(visible(nav.children[20]),"Changed selection must scroll into view");
            window.added=[...tabs,{id:"created",title:"New remote tab",supportsTabMetadata:true}];
            selected="created";renderSessions(added);
            check(visible(nav.lastElementChild),"Newly created selection must scroll into view");
            window.renamed=added.map(tab=>({...tab,title:"Renamed remote project",isLocked:true}));
            renderSessions(renamed);
            check((nav.children[10].querySelector(".session-name")||nav.children[10].children[0]).textContent==="Renamed remote project","Existing titles update");
            check(nav.children[10].children[1].disabled,"Existing locks update");
            nav[offset]=200;window.beforeRemove=nav[offset];
            renderSessions(renamed.filter(tab=>tab.id!==tabs[0].id));
            check(Math.abs(nav[offset]-beforeRemove)<1,"Removing another tab retains the scroll offset");
            renderSessions([...renamed].reverse());
            check(nav.firstElementChild.dataset.sessionId==="created","Host ordering remains authoritative");
            nav.firstElementChild.children[2].click();
            check($("tabEditor").open&&$("tabLocked").checked,"Sidebar and strip retain tab settings");
            $("tabCancel").click();
            selected="legacy";renderSessions([{id:"legacy",title:"Old host"}]);
            check(nav.firstElementChild.children.length===2,"Legacy tabs omit unsupported metadata controls");
            check(nav[offset]===0&&!wheel({deltaY:80}).defaultPrevented,"A short list does not consume wheel events");
            selected=null;renderSessions([]);
            check(nav.children.length===0&&nav[offset]===0,"Empty lists reset safely");
            if(sidebarLayout){
              pair(true);
              check($("sessionSidebar").getClientRects().length===0,"Pairing hides the sidebar with the rest of the app");
              pair(false);
              selected=tabs[0].id;renderSessions(tabs);
              $("messages").style.minHeight="2000px";
              const root=document.scrollingElement;
              root.scrollTop=120;
              check(root.scrollTop===120&&$("sessionSidebar").getBoundingClientRect().top===0,"Sidebar stays fixed while reading a long conversation");
              nav.scrollTop=nav.scrollHeight;
              check(root.scrollTop===120&&visible(nav.lastElementChild),"Browsing tabs does not move the conversation");
              const savedTop=nav.scrollTop;
              root.scrollTop=240;
              check(nav.scrollTop===savedTop,"Reading the conversation does not move the tab list");
              selected=tabs[2].id;renderSessions(tabs);
              check(visible(nav.children[2])&&root.scrollTop===240,"Revealing a selected tab scrolls only the sidebar");
              $("messages").style.minHeight="";root.scrollTop=0;
              selected=null;renderSessions([]);
            }
            })();
            """)
            try await testRemoteProgress(webView: webView)
        }
        print("Remote tabs (\(sidebar ? "Mac sidebar" : "browser strip")): WebKit scrolling, progress, polling, selection, focus, and controls passed at 320-1100pt widths and 340-700pt heights")
    }

    @MainActor
    private static func testRemoteProgress(webView: WKWebView) async throws {
        _ = try await webView.callAsyncJavaScript("""
        // Offscreen WebKit pauses animation frames; let disclosure/scroll events settle instead.
        const settle=()=>new Promise(resolve=>setTimeout(resolve,50));
        const running={id:"working",title:"Active project",isStreaming:true,status:"Running focused tests",
          queuedCount:2,supportsTabMetadata:true,isLocked:true,messages:[
            {id:"prompt",role:"user",text:"Update this project"},
            {id:"reply",role:"assistant",text:"Preparing the update",thinking:"Inspecting the relevant code",
             activities:[{id:"tool",toolName:"bash",title:"Running focused tests",state:"running",input:"make test"}]}
          ]};
        const ready={id:"ready",title:"Other project",isStreaming:false,queuedCount:0,messages:[]};
        selected=running.id;connection(true);renderSessions([running,ready]);render(running);await settle();
        const progress=$("sessionProgress"),label=$("sessionProgressText");
        if(!sidebarLayout){
          check(progress.classList.contains("hidden")&&!nav.querySelector(".brain-indicator"),"Browser keeps its existing tab presentation");
          check($("messages").querySelector(".run-status .spinner"),"Browser retains its transcript progress indicator");
        }else{
          const tab=nav.firstElementChild,button=tab.children[0],brain=button.querySelector(".brain-indicator");
          const status=button.querySelector(".session-status"),pinnedBrain=progress.querySelector(".brain-indicator");
          check(label.textContent==="Running focused tests · 2 queued"&&status.textContent===label.textContent,"Host activity and queue count appear in the sidebar and pinned status");
          check(button.getAttribute("aria-label").includes("Active project — Running focused tests · 2 queued · Locked"),"Tab accessibility includes title, activity, queue and lock");
          check(progress.getAttribute("role")==="status"&&progress.getAttribute("aria-live")==="polite","Selected progress is announced accessibly");
          check(brain.getAttribute("aria-hidden")==="true"&&brain.querySelector("path").getAttribute("d").length>0,"Brain graphic has a path without duplicating accessible status");
          const reduced=matchMedia("(prefers-reduced-motion: reduce)").matches;
          check(getComputedStyle(brain).animationName===(reduced?"none":"pulse"),"Active brain animates unless Reduce Motion is enabled");
          check(getComputedStyle(pinnedBrain).visibility==="visible","Current progress has a visible brain");
          check(!$("messages").querySelector(".run-status .spinner"),"Mac progress is pinned rather than duplicated at the transcript bottom");
          check(!$("stop").classList.contains("hidden"),"Stop remains available while working");
          const tool=$("messages").querySelector(".steps");
          tool.open=true;await settle();
          check(tool.querySelector(".status-icon.running")&&tool.textContent.includes("Running focused tests"),"Detailed tool activity stays available");
          $("draft").value="Keep my draft";button.focus();
          const textNode=status.firstChild,pinnedText=label.firstChild;
          for(let index=0;index<10;index++){renderSessions([{...running},{...ready}]);render({...running})}
          check(button===nav.firstElementChild.children[0]&&brain===button.querySelector(".brain-indicator"),"Polling preserves controls and running animation nodes");
          check(status.firstChild===textNode&&label.firstChild===pinnedText,"Unchanged polls do not rewrite or reannounce progress text");
          check(document.activeElement===button&&$("draft").value==="Keep my draft","Progress polling preserves focus and drafts");
          check($("messages").querySelector(".steps").open,"Progress polling preserves open tool details");
          $("messages").style.minHeight="2000px";document.scrollingElement.scrollTop=160;await settle();
          const bounds=progress.getBoundingClientRect();
          check(bounds.top>=0&&bounds.bottom<=innerHeight&&bounds.left>=$("sessionSidebar").getBoundingClientRect().right,"Pinned progress remains visible and separate from the sidebar while reading older output");
          check(document.documentElement.scrollWidth<=innerWidth+1,"Progress must fit narrow windows");
          connection(false);
          check(label.textContent==="Reconnecting… Last known: Running focused tests · 2 queued","Disconnect labels stale progress explicitly");
          check(status.textContent.startsWith("Last known:")&&button.getAttribute("aria-label").includes("Last known:"),"Background tab status also marks stale data");
          check(getComputedStyle(brain).animationName==="none"&&getComputedStyle(pinnedBrain).animationName==="none","Disconnect pauses activity animation");
          check(getComputedStyle(tool.querySelector(".status-icon.running")).animationName==="none","Stale tool activity must not keep animating");
          render(running);connection(true);
          check(label.textContent==="Running focused tests · 2 queued"&&!status.textContent.includes("Last known:"),"Reconnect restores identical snapshots without waiting for a transcript change");
          const preparing={...running,status:"Preparing context...",queuedCount:0};
          renderSessions([preparing,ready]);render(preparing);
          check(label.textContent==="Preparing context..."&&status.textContent==="Preparing context...","Activity updates without a tab change");
          const fallback={...running,status:"",queuedCount:0};
          renderSessions([fallback,ready]);render(fallback);
          check(label.textContent==="Working…","Streaming without a status still shows progress");
          const literal={...running,status:"<img src=x onerror=alert(1)>",title:"<script>not markup</script>"};
          renderSessions([literal,ready]);render(literal);
          check(label.textContent.includes("<img")&&!progress.querySelector("img")&&!button.querySelector("script"),"Host titles and status stay plain text");
          const longStatus={...running,status:"Processing a detailed project task ".repeat(30)};
          renderSessions([longStatus,ready]);render(longStatus);
          check(label.getBoundingClientRect().height<=parseFloat(getComputedStyle(label).lineHeight)*2+1,"Long status is capped at two lines rather than covering the conversation");
          check(progress.title===longStatus.status+" · 2 queued","Full status remains available on hover and in accessible text");
          for(const [session,expected] of [
            [{...running,isStreaming:false,status:null,queuedCount:0},"Ready"],
            [{...running,isStreaming:false,status:null,queuedCount:3},"Ready · 3 queued"],
            [{...running,isStreaming:false,status:null,queuedCount:0,canResume:true},"Paused"]
          ]){
            renderSessions([session,ready]);render(session);
            check(label.textContent===expected&&status.textContent===expected,"Completion, queued and resumable states stay accurate");
            check(getComputedStyle(brain).visibility==="hidden"&&getComputedStyle(brain).animationName==="none","Finished work no longer animates");
            check($("stop").classList.contains("hidden"),"Finished work removes Stop");
          }
          check(!$("resume").classList.contains("hidden"),"Paused work retains Resume");
          renderSessions([running,ready]);
          nav.children[1].children[0].click();
          check(selected===ready.id&&label.textContent==="Ready","Selecting another tab immediately switches progress");
          renderSessions([running,ready]);render(ready);
          check(nav.firstElementChild.dataset.streaming==="true"&&progress.dataset.streaming==="false","Background work remains visible without marking the selected tab busy");
          selected="legacy";renderSessions([{id:"legacy",title:"Older host"}]);
          check(label.textContent==="Ready"&&!nav.firstElementChild.children[0].title.includes("undefined"),"Older host snapshots do not leak missing fields");
          $("messages").style.minHeight="";document.scrollingElement.scrollTop=0;
        }
        selected=null;renderSessions([]);render(null);await settle();
        check(progress.classList.contains("hidden")&&label.textContent==="","Removing every tab clears selected progress");
        """, arguments: [:], in: nil, contentWorld: .page)
    }
}
