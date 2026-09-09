import AppKit
import WebKit

@MainActor
private final class RemoteTabPageDelegate: NSObject, WKNavigationDelegate {
    var finished = false
    var error: Error?

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
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 740, height: 500),
                                configuration: configuration)
        let delegate = RemoteTabPageDelegate()
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
        pair(false);
        window.tabs=Array.from({length:32},(_,index)=>({
          id:`tab-${index}`,title:`Remote project ${index} with a long name`,
          customTitle:"",isLocked:index===2,supportsTabMetadata:true
        }));
        window.nav=$("sessions");
        window.visible=tab=>{
          const bounds=tab.getBoundingClientRect(),viewport=nav.getBoundingClientRect();
          const overlap=Math.min(bounds.right,viewport.right)-Math.max(bounds.left,viewport.left);
          return overlap>=Math.min(bounds.width,viewport.width)-1;
        };
        window.wheel=options=>{
          const event=new WheelEvent("wheel",{bubbles:true,cancelable:true,...options});
          nav.lastElementChild.children[0].dispatchEvent(event);
          return event;
        };
        void 0;
        """)

        for width in [320, 440, 740] {
            window.setContentSize(NSSize(width: width, height: 500))
            webView.frame.size = NSSize(width: width, height: 500)
            _ = try await webView.evaluateJavaScript("""
            (()=>{
            selected=null;renderSessions([]);selected=tabs[0].id;renderSessions(tabs);
            check(nav.children.length===32,"No tab count limit");
            check(nav.scrollWidth>nav.clientWidth&&nav.clientWidth>60,"Tab strip must overflow inside the window");
            check(document.documentElement.scrollWidth<=innerWidth+1,"Tabs must not widen the whole page");
            for(const id of ["newSession","mode","forget"]){
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
            check(wheel({deltaY:80}).defaultPrevented&&nav.scrollLeft>=79,"Mouse wheel scrolls the tabs");
            check(wheel({deltaY:-40}).defaultPrevented&&nav.scrollLeft<=41,"Reverse wheel scrolls back");
            check(followOutput,"Scrolling tabs must not disable transcript following");
            const beforeLine=nav.scrollLeft;
            wheel({deltaY:2,deltaMode:1});
            check(Math.abs(nav.scrollLeft-beforeLine-32)<1,"Line-mode wheels use pixel distances");
            const beforePage=nav.scrollLeft;
            wheel({deltaY:1,deltaMode:2});
            check(Math.abs(nav.scrollLeft-beforePage-nav.clientWidth)<1,"Page-mode wheels use the strip width");
            for(let index=0;index<100;index++)wheel({deltaY:100});
            check(visible(nav.lastElementChild),"Scrolling must reach the final tab");
            window.lastButton=nav.lastElementChild.children[0];
            lastButton.focus();
            window.savedLeft=nav.scrollLeft;
            for(let index=0;index<10;index++)renderSessions(tabs.map(tab=>({...tab})));
            check(nav.lastElementChild.children[0]===lastButton,"Polling must reuse existing tab controls");
            check(document.activeElement===lastButton,"Polling must retain keyboard focus");
            check(Math.abs(nav.scrollLeft-savedLeft)<1,"Polling must not reset scrolling or snap to selection");
            lastButton.click();renderSessions(tabs);
            check(selected===tabs[31].id&&visible(nav.lastElementChild),"Last tab must be selectable");
            check(lastButton.getAttribute("aria-current")==="true","Selection is accessible");
            nav.scrollLeft=0;renderSessions(tabs);
            check(nav.scrollLeft===0,"Browsing away from the selected tab survives refresh");
            selected=tabs[20].id;renderSessions(tabs);
            check(visible(nav.children[20]),"Changed selection must scroll into view");
            window.added=[...tabs,{id:"created",title:"New remote tab",supportsTabMetadata:true}];
            selected="created";renderSessions(added);
            check(visible(nav.lastElementChild),"Newly created selection must scroll into view");
            window.renamed=added.map(tab=>({...tab,title:"Renamed remote project",isLocked:true}));
            renderSessions(renamed);
            check(nav.children[10].children[0].textContent==="Renamed remote project","Existing titles update");
            check(nav.children[10].children[1].disabled,"Existing locks update");
            nav.scrollLeft=200;window.beforeRemove=nav.scrollLeft;
            renderSessions(renamed.filter(tab=>tab.id!==tabs[0].id));
            check(Math.abs(nav.scrollLeft-beforeRemove)<1,"Removing another tab retains the scroll offset");
            renderSessions([...renamed].reverse());
            check(nav.firstElementChild.dataset.sessionId==="created","Host ordering remains authoritative");
            selected="legacy";renderSessions([{id:"legacy",title:"Old host"}]);
            check(nav.firstElementChild.children.length===2,"Legacy tabs omit unsupported metadata controls");
            check(nav.scrollLeft===0&&!wheel({deltaY:80}).defaultPrevented,"A short strip does not consume wheel events");
            selected=null;renderSessions([]);
            check(nav.children.length===0&&nav.scrollLeft===0,"Empty lists reset safely");
            })();
            """)
        }
        print("Remote tabs: real WebKit scrolling, polling, selection, focus, and controls passed at 320/440/740pt")
    }
}
