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
            check(nav.children[10].children[0].textContent==="Renamed remote project","Existing titles update");
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
        }
        print("Remote tabs (\(sidebar ? "Mac sidebar" : "browser strip")): WebKit scrolling, polling, selection, focus, and controls passed at 320-1100pt widths and 340-700pt heights")
    }
}
