import AppKit
import WebKit

@MainActor
private final class RemoteUIUpdateDelegate: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var loads = 0
    var error: Error?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {}

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loads += 1 }
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
    static func testRemoteUIUpdates(html: String, baseURL: URL, token: String,
                                    sessionID: UUID, revision: String) async throws {
        for sidebar in [false, true] {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            // The suite runs without activating a Mac app; model foreground/background deterministically.
            configuration.userContentController.addUserScript(WKUserScript(
                source: "window.fixtureHidden=false;Object.defineProperty(document,'hidden',{get:()=>window.fixtureHidden});",
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
            let delegate = RemoteUIUpdateDelegate()
            if sidebar { configuration.userContentController.add(delegate, name: "cantripRemoteUnpair") }
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 740, height: 500),
                                    configuration: configuration)
            webView.navigationDelegate = delegate
            let window = NSWindow(contentRect: webView.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = webView
            defer { webView.stopLoading(); window.close() }
            let oldRevision = String(repeating: "0", count: 64)
            webView.loadHTMLString(html.replacingOccurrences(of: revision, with: oldRevision), baseURL: baseURL)
            try await waitForRemoteUILoad(delegate, count: 1)
            _ = try await webView.callAsyncJavaScript("""
            window.check=(value,message)=>{if(!value)throw Error(message)};
            check(uiRevision===oldRevision,"Fixture must start with an older UI");
            const originalSchedule=scheduleUIReload,originalFetch=fetch,originalAPI=api;
            scheduleUIReload=()=>{};
            token=pairingToken;localStorage.cantripToken=token;pair(false);connection(true);
            selected=chatID;followOutput=true;uiLastInteraction=0;
            const nextRevision=revision;
            const question={id:"waiting-question",kind:"question",title:"Choose",detail:"Fixture",
              choices:["A","B"],allowsFreeform:true,expiresAt:9999999999};
            const fresh=()=>{blockedUIRevision=null;uiReloading=false;pendingUIRevision=nextRevision;uiLastInteraction=0};
            try{
              observeUIRevision(undefined);check(pendingUIRevision===null,"Legacy hosts must not trigger reloads");
              observeUIRevision("invalid");check(pendingUIRevision===null,"Invalid versions must not trigger reloads");
              observeUIRevision(uiRevision);check(pendingUIRevision===null,"Unchanged UI does not reload");
              observeUIRevision(nextRevision);check(pendingUIRevision===nextRevision,"Changed UI must be detected");
              check(canReloadUI(),`An idle connected page can update (hidden=${document.hidden}, refresh=${Boolean(refreshTask)}, composing=${uiComposing}, follow=${followOutput})`);
              window.fixtureHidden=true;check(!canReloadUI(),"Background pages must wait until visible");window.fixtureHidden=false;
              sessionItems=[{id:chatID,isStreaming:true}];
              check(canReloadUI(),"An agent running on the host does not block a page update");
              for(const id of ["inputEditor","tabEditor","modelEditor","privateEditor","desktopEditor","promptReader"]){
                $(id).showModal();check(!canReloadUI(),`${id} must defer updates`);$(id).close();
              }
              uiComposing=true;check(!canReloadUI(),"IME composition must not be interrupted");uiComposing=false;
              uiLastInteraction=Date.now();check(!canReloadUI(),"Recent typing must not be interrupted");uiLastInteraction=0;
              followOutput=false;check(!canReloadUI(),"Reading older history must not lose its position");followOutput=true;
              connection(false);check(!canReloadUI(),"Disconnected pages must not navigate away");connection(true);
              $("send").disabled=true;check(!canReloadUI(),"Composer acknowledgement must settle first");$("send").disabled=false;
              chatInputSaving=true;check(!canReloadUI(),"Question replies must finish first");chatInputSaving=false;
              movingTab=true;check(!canReloadUI(),"Tab reordering must finish first");movingTab=false;
              draggedTabID=chatID;check(!canReloadUI(),"Dragging must finish first");draggedTabID=null;
              loadingHistory=true;check(!canReloadUI(),"History reads must finish first");loadingHistory=false;

              let releaseWrite;
              window.fetch=()=>new Promise(resolve=>{releaseWrite=resolve});
              const writing=originalAPI(`/api/v1/sessions/${chatID}/messages`,{method:"POST",body:"{}"});
              check(uiActiveWrites===1&&!canReloadUI(),"All mutations are tracked, not only composer sends");
              await reloadUpdatedUI();
              check(!uiReloading&&!sessionStorage.getItem(uiReloadStorageKey),"An active write must not start navigation");
              releaseWrite({ok:true,json:async()=>({accepted:true})});await writing;
              check(uiActiveWrites===0&&canReloadUI(),"Write completion releases the update gate");
              window.fetch=async()=>{throw Error("Simulated lost acknowledgement")};
              try{await originalAPI("/api/v1/sessions/fixture/messages",{method:"POST",body:"{}"});throw Error("Expected failure")}
              catch(error){check(error.message==="Simulated lost acknowledgement","Original mutation failure must propagate")}
              check(uiActiveWrites===0&&uiMutationWarning.includes("not resent"),"Uncertain-send warning survives an update");
              window.fetch=originalFetch;

              $("draft").value="Keep this answer 🚀";$("mode").value="inject";
              tabDrafts.set("another-tab","Another unsent draft");
              chatInputReply={id:question.id,sessionID:chatID,token};
              const password=document.createElement("input");password.type="password";password.value="never-save-this-secret";
              $("inputCards").append(password);
              const owner=await uiStateOwner(token),state=captureUIState(owner,uiRevision);
              const encoded=JSON.stringify(state);
              check(!encoded.includes(token)&&!encoded.includes(password.value),"Neither pairing tokens nor secure fields enter reload storage");
              sessionStorage.setItem(uiReloadStorageKey,encoded);
              selected=null;tabDrafts.clear();$("draft").value="";$("mode").value="auto";chatInputReply=null;
              await restoreUIState();
              check(selected===chatID&&$("draft").value==="Keep this answer 🚀"&&$("mode").value==="inject","Selection, text and delivery mode are restored");
              check(tabDrafts.get("another-tab")==="Another unsent draft","Drafts in other tabs are restored");
              check(chatInputReply.id===question.id,"Question replies retain their explicit target");
              check($("actionError").textContent.includes("not resent"),"Lost-acknowledgement warning must not disappear");
              check(!sessionStorage.getItem(uiReloadStorageKey),"Reload state is consumed once");
              appendChatInputs(document.createElement("div"),{id:chatID,pendingInputs:[question]});
              check(chatInputReply.id===question.id,"An active question keeps the restored target");
              appendChatInputs(document.createElement("div"),{id:chatID,pendingInputs:[{...question,id:"different-question"}]});
              check(chatInputReply.id===question.id,"An expired question draft must not silently answer another question");
              appendChatInputs(document.createElement("div"),{id:chatID,pendingInputs:[]});
              check(chatInputReply.id===question.id,"An expired question draft must not silently become a new task");
              password.remove();

              sessionStorage.setItem(uiReloadStorageKey,JSON.stringify({...state,owner:"different-pairing"}));
              selected=null;tabDrafts.clear();$("draft").value="";
              await restoreUIState();
              check(selected===null&&!$("draft").value&&!tabDrafts.size,"A different pairing must never inherit saved drafts");
              check(!sessionStorage.getItem(uiReloadStorageKey),"Mismatched pairing state is discarded");
              sessionStorage.setItem(uiReloadStorageKey,JSON.stringify({...state,revision:nextRevision}));
              await restoreUIState();
              check(blockedUIRevision===nextRevision&&$("uiUpdateStatus").textContent.includes("reload loop"),"An old cached response must not cause a reload loop");
              fresh();
              const originalSetItem=Storage.prototype.setItem;
              Storage.prototype.setItem=function(){throw Error("Storage unavailable")};
              try{await reloadUpdatedUI()}finally{Storage.prototype.setItem=originalSetItem}
              check(!uiReloading&&blockedUIRevision===nextRevision&&$("draft").value===state.drafts.find(([id])=>id===chatID)[1],
                "Storage failure must preserve the live page and draft");
              check($("uiUpdateStatus").textContent.includes("Storage unavailable"),"Storage failure is visible");
              clearUIReloadState();
              check(!pendingUIRevision&&!sessionStorage.getItem(uiReloadStorageKey),"Unpair clears any reload state");
              sessionStorage.setItem(uiReloadStorageKey,"invalid JSON");
              await restoreUIState();
              check(uiRestoreFailed&&!canReloadUI()&&sessionStorage.getItem(uiReloadStorageKey)==="invalid JSON",
                "Unreadable state must be retained and protected from an automatic overwrite");
              clearUIReloadState();
              fresh();
              const originalOwner=uiStateOwner;
              let releaseOwner;uiStateOwner=()=>new Promise(resolve=>{releaseOwner=resolve});
              try{
                const updating=reloadUpdatedUI();uiLastInteraction=Date.now();releaseOwner(owner);await updating;
                check(!uiReloading&&!sessionStorage.getItem(uiReloadStorageKey),"Typing during update preparation must defer navigation");
              }finally{uiStateOwner=originalOwner}
              clearUIReloadState();
              fresh();
              const originalNavigate=navigateUpdatedUI;
              navigateUpdatedUI=()=>{};
              try{
                await reloadUpdatedUI();
                check(uiNavigating&&$("app").inert,"Inputs are locked during the final navigation, after drafts are saved");
                try{await originalAPI("/api/v1/sessions/fixture/messages",{method:"POST",body:"{}"});throw Error("Expected navigation guard")}
                catch(error){check(error.message.includes("this request was not sent"),"No new submission may race navigation")}
                pauseUIReload(nextRevision,new Error("Simulated navigation timeout"));
                check(!uiNavigating&&!$("app").inert&&!sessionStorage.getItem(uiReloadStorageKey),
                  "Failed navigation must reopen the original UI without stale saved drafts");
                check($("draft").value==="Keep this answer 🚀","Failed navigation retains the original live draft");
              }finally{navigateUpdatedUI=originalNavigate}
              clearUIReloadState();
            }finally{window.fetch=originalFetch;api=originalAPI;scheduleUIReload=originalSchedule}
            $("draft").value="Preserve across real navigation";$("mode").value="auto";
            tabDrafts.set("another-tab","Keep the other tab");
            selected=chatID;chatInputReply={id:question.id,sessionID:chatID,token};
            uiMutationWarning="";$("actionError").textContent="";$("uiUpdateStatus").textContent="";
            $("draft").focus();$("draft").setSelectionRange(4,12);
            fresh();pendingUIRevision=null;
            await refresh();
            check(pendingUIRevision===nextRevision,"Existing session polling detects the host UI revision");
            return true;
            """, arguments: ["oldRevision": oldRevision, "revision": revision,
                               "pairingToken": token, "chatID": sessionID.uuidString],
               in: nil, contentWorld: .page)
            try await waitForRemoteUILoad(delegate, count: 2)
            for _ in 0..<100 {
                let ready = try await webView.evaluateJavaScript("renderedSession !== null && !refreshTask")
                if ready as? Bool == true { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let restored = try await webView.callAsyncJavaScript("""
            if(uiRevision!==revision)throw Error("Navigation did not load the new host UI");
            if(selected!==chatID||$("draft").value!=="Preserve across real navigation"
              ||tabDrafts.get("another-tab")!=="Keep the other tab"||$("mode").value!=="auto")
              throw Error("Real navigation lost draft state");
            if(chatInputReply?.id!=="waiting-question")
              throw Error("Real navigation lost the reply target");
            if($("draft").selectionStart!==4||$("draft").selectionEnd!==12)
              throw Error("Real navigation lost the draft selection");
            if(sessionStorage.getItem(uiReloadStorageKey))throw Error("Reload state was not consumed");
            if(pendingUIRevision||blockedUIRevision)throw Error("Updated page must not reload again");
            return true;
            """, arguments: ["revision": revision, "chatID": sessionID.uuidString], in: nil, contentWorld: .page)
            precondition(restored as? Bool == true)
            try await Task.sleep(for: .milliseconds(1800))
            precondition(delegate.loads == 2, "The updated UI must remain stable instead of reloading repeatedly")
        }
        print("Remote UI updates: revision polling, safe deferral, draft/target restoration, failures and real WebKit navigation passed")
    }

    @MainActor
    private static func waitForRemoteUILoad(_ delegate: RemoteUIUpdateDelegate, count: Int) async throws {
        for _ in 0..<300 {
            if delegate.loads >= count || delegate.error != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        if let error = delegate.error { throw error }
        precondition(delegate.loads == count, "Remote UI navigation did not complete")
    }
}
