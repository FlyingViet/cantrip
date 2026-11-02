import Foundation
import JavaScriptCore

extension SessionTabTests {
    /// The browser Remote's Mac Settings sheet draws `/api/v1/settings`: hidden and read-only fields,
    /// changes posted with the loaded revision in their JSON types, 422 and 409 answers, a typed draft
    /// surviving a refresh, a change waiting to be kept, and Replace Pairing Token moving this browser
    /// to the new token without ever showing it.
    @MainActor
    static func testSettingsManifestWeb() throws {
        // The sheet's script has no Swift escapes, so the source reads as the browser gets it.
        let page = try String(contentsOfFile: "Sources/Cantrip/RemoteControlServer.swift", encoding: .utf8)
        guard let start = page.range(of: "    let macSettingsState="),
              let end = page.range(of: "    function openDesktop(", range: start.upperBound..<page.endIndex) else {
            preconditionFailure("The web app has no Mac Settings script")
        }
        precondition(!page[start.lowerBound..<end.lowerBound].contains("\\"), "Keep the Mac Settings script free of Swift escapes")
        let context = JSContext()!
        context.exceptionHandler = { _, error in fatalError("Mac Settings JavaScript: \(error?.toString() ?? "")") }
        context.evaluateScript(#"""
        let token="old-token",tokenHandoff=null,tabSaving=false,movingTab=false,editingTab=null,refreshes=0,confirms=[],timers=[],calls=[],replies=[];
        const localStorage={};
        function refresh(){refreshes++;return Promise.resolve()}
        function confirm(text){confirms.push(text);return true}
        function setTimeout(callback,ms){timers.push({callback,ms});return timers.length}
        function clearTimeout(){}
        function runTimers(ms){const due=timers.filter(timer=>timer.ms===ms);timers=timers.filter(timer=>timer.ms!==ms);for(const timer of due)timer.callback()}
        function api(path,options={}){calls.push({path,method:options.method||"GET",body:options.body?JSON.parse(options.body):null,token});
          const reply=replies.shift();if(!reply)return Promise.reject(new Error("No reply"));
          if(reply.status){const error=new Error(reply.error||`HTTP ${reply.status}`);error.status=reply.status;error.data=reply.data||{error:reply.error};return Promise.reject(error)}
          return Promise.resolve(JSON.parse(JSON.stringify(reply)))}
        function node(tag){const classes=new Set(),listeners={};return {tagName:String(tag).toUpperCase(),children:[],attributes:{},value:"",checked:false,disabled:false,textContent:"",id:"",scrollTop:0,open:false,
          get className(){return [...classes].join(" ")},set className(value){classes.clear();for(const name of String(value).split(" ").filter(Boolean))classes.add(name)},
          classList:{add(...names){for(const name of names)classes.add(name)},remove(...names){for(const name of names)classes.delete(name)},
            toggle(name,on=!classes.has(name)){if(on)classes.add(name);else classes.delete(name);return on},contains(name){return classes.has(name)}},
          append(...items){for(const item of items)this.children.push(typeof item==="string"?{text:item}:item)},replaceChildren(...items){this.children=[];this.append(...items)},
          setAttribute(name,value){this.attributes[name]=String(value)},focus(){document.activeElement=this},select(){},setSelectionRange(start,end){this.selection=[start,end]},
          addEventListener(name,listener){(listeners[name]||=[]).push(listener)},showModal(){this.open=true},close(){this.open=false;for(const listener of listeners.close||[])listener()}}}
        const document={activeElement:null,createElement:node},elements={};const $=id=>elements[id]||(elements[id]=node("div"));
        function el(tag,cls="",text){const n=document.createElement(tag);if(cls)n.className=cls;if(text!==undefined)n.textContent=text;return n}
        function all(root=$("macSettingsBody"),found=[]){found.push(root);for(const child of root.children||[])all(child,found);return found}
        function byID(id){return all().find(item=>item.id===id)}
        function control(key){return byID("macSetting-"+key)}
        function row(key){return all().find(item=>String(item.className||"").startsWith("settings-field")&&all(item).some(child=>child.id==="macSetting-"+key))}
        function text(root){return all(root).map(item=>item.text??item.textContent??"").join(" ")}
        function sent(index){return JSON.stringify(calls[index].body)}
        function manifest(revision,values={},pending=null){const data={version:1,revision,mac:"Fixture Mac",local:false,pages:[
          {id:"macs",title:"Macs",sections:[{id:"remote",title:"Remote control",footer:"Paired devices connect here.",fields:[
            {key:"remoteControlEnabled",type:"toggle",label:"Remote control",value:true,readOnly:true,readOnlyReason:"Change this in Cantrip's Settings on the Mac."},
            {key:"remoteLANPort",type:"port",label:"Direct port",value:0,min:0,max:65535,zeroLabel:"Automatic",placeholder:"Automatic",guarded:true,visibleWhen:{key:"remoteControlEnabled",values:[true]}},
            {key:"rotatePairingToken",type:"action",label:"Replace Pairing Token",destructive:true,guarded:true,confirmation:"Every other device has to pair again."}]}]},
          {id:"home",title:"Home & tabs",sections:[
            {id:"home",title:"Cantrip Home",fields:[
              {key:"cantripHomeEnabled",type:"toggle",label:"Cantrip Home",value:false},
              {key:"cantripHomeParallelRuns",type:"integer",label:"Parallel runs",value:1,min:1,max:4,step:1,visibleWhen:{key:"cantripHomeEnabled",values:[true]}},
              {key:"copilotIdleReleaseMinutes",type:"choice",label:"Release idle Copilot tabs",value:30,
               choices:[{value:0,label:"Never"},{value:30,label:"30 minutes"},{value:60,label:"1 hour"},{value:120,label:"2 hours",disabled:true}]}]},
            {id:"cli",title:"Command-line tools",link:true,summary:"4 paths",footer:"Where each agent's CLI is on the Mac.",fields:[
              {key:"claudePath",type:"path",label:"Claude Code",value:"/usr/local/bin/claude",maxLength:1024,readOnly:true,readOnlyReason:"Change this in Cantrip's Settings on the Mac."}]}]},
          {id:"tools",title:"Tools",sections:[{id:"endpoint",title:"OpenAI-compatible API",fields:[
            {key:"localAPIKey",type:"secret",label:"API key",isSet:false,maxLength:1024},
            {key:"panelOpacity",type:"number",label:"Panel opacity",value:0.7,min:0.3,max:1,step:0.05,format:"percent"},
            {key:"localSystemPrompt",type:"text",label:"System prompt",value:"Be brief",multiline:true,maxLength:4000},
            {key:"makeOpenAIEndpointKey",type:"action",label:"Make Proxy Key"},
            {key:"openAIEndpointStatus",type:"info",label:"Status",value:"Port 8080 is in use.",tone:"error"}]}]}]};
          for(const page of data.pages)for(const section of page.sections)for(const field of section.fields)
            if(field.key in values){if(field.type==="secret")field.isSet=values[field.key];else field.value=values[field.key]}
          if(pending)data.pending=pending;return data}
        """#)
        context.evaluateScript(String(page[start.lowerBound..<end.lowerBound]))
        func check(_ script: String, _ message: String) {
            precondition(context.evaluateScript(script)?.toBool() == true, message)
        }

        // Opening loads the manifest and draws it: read-only, hidden, collapsed and formatted fields.
        context.evaluateScript(#"replies.push(manifest("r1"));$("tabMacSettings").onclick();"#)
        check(#"calls.length===1&&calls[0].path==="/api/v1/settings"&&calls[0].method==="GET"&&$("macSettingsEditor").open"#,
              "Mac Settings loads the manifest when it opens")
        check(#"$("macSettingsTitle").textContent==="Mac Settings · Fixture Mac"&&text().includes("Home & tabs")&&text().includes("Paired devices connect here.")"#,
              "Pages, sections and footers are drawn")
        check(#"""
        control("remoteControlEnabled").disabled&&text(row("remoteControlEnabled")).includes("Change this in Cantrip's Settings on the Mac.")
          &&control("remoteControlEnabled").attributes["aria-describedby"].includes("macSetting-remoteControlEnabled-reason")
        """#, "Read-only fields are disabled and say why")
        check(#"control("remoteLANPort").value===""&&control("remoteLANPort").placeholder==="Automatic""#, "Port 0 shows its zero label")
        check(#"control("cantripHomeParallelRuns")===undefined"#, "visibleWhen hides a field while its condition is false")
        check(#"""
        all().some(item=>item.tagName==="DETAILS"&&!item.open&&text(item).includes("4 paths")&&text(item).includes("Command-line tools"))
          &&all().some(item=>item.tagName==="LABEL"&&item.htmlFor==="macSetting-copilotIdleReleaseMinutes")
        """#, "Linked sections start collapsed with their summary; controls have labels")
        check(#"""
        control("panelOpacity").attributes["aria-valuetext"]==="70%"&&control("openAIEndpointStatus").className.includes("error")
          &&control("rotatePairingToken").className.includes("destructive")&&text(row("localAPIKey")).includes("Not set")
          &&byID("macSetting-localAPIKey-clear").disabled&&control("copilotIdleReleaseMinutes").children[3].disabled
        """#, "Percent sliders, info tones, destructive actions, secrets and disabled choices")

        // A choice posts its value with its JSON type and the loaded revision; the reply is drawn.
        context.evaluateScript(#"""
        replies.push(manifest("r2",{copilotIdleReleaseMinutes:60}));const pick=control("copilotIdleReleaseMinutes");pick.value="2";pick.onchange();
        """#)
        check(#"sent(1)==='{"revision":"r1","changes":{"copilotIdleReleaseMinutes":60}}'&&control("copilotIdleReleaseMinutes").value==="2""#,
              "A numeric choice is sent as a number with the loaded revision")
        context.evaluateScript(#"""
        replies.push(manifest("r3",{copilotIdleReleaseMinutes:60,cantripHomeEnabled:true}));const home=control("cantripHomeEnabled");home.checked=true;home.onchange();
        """#)
        check(#"sent(2)==='{"revision":"r2","changes":{"cantripHomeEnabled":true}}'&&control("cantripHomeParallelRuns").value==="1""#,
              "A toggle saves and the field it reveals appears")

        // 422: the reason shows next to the field and overall; nothing changes.
        context.evaluateScript(#"""
        replies.push({status:422,data:{error:"Parallel runs is 1–4.",fields:{cantripHomeParallelRuns:"Parallel runs is 1–4."}}});
        const runs=control("cantripHomeParallelRuns");runs.focus();runs.value="9";runs.onkeydown({key:"Enter",preventDefault(){}});
        """#)
        check(#"""
        sent(3)==='{"revision":"r3","changes":{"cantripHomeParallelRuns":9}}'&&byID("macSetting-cantripHomeParallelRuns-problem").textContent==="Parallel runs is 1–4."
          &&control("cantripHomeParallelRuns").attributes["aria-invalid"]==="true"&&$("macSettingsError").textContent==="Parallel runs is 1–4."
          &&document.activeElement===control("cantripHomeParallelRuns")&&control("cantripHomeParallelRuns").value==="1"
        """#, "A refused change names the problem next to its field and keeps focus there")

        // 409: redrawn from the settings in the error, with its message.
        context.evaluateScript(#"""
        replies.push({status:409,data:{error:"Settings changed on another device. They've been reloaded; try again.",settings:manifest("r4",{cantripHomeEnabled:true,copilotIdleReleaseMinutes:0})}});
        const homeOff=control("cantripHomeEnabled");homeOff.checked=false;homeOff.onchange();
        """#)
        check(#"""
        calls[4].body.revision==="r3"&&macSettingsState.data.revision==="r4"&&control("copilotIdleReleaseMinutes").value==="0"&&control("cantripHomeEnabled").checked
          &&$("macSettingsError").textContent.includes("another device")&&!byID("macSetting-cantripHomeParallelRuns-problem")
        """#, "A stale save redraws from the current settings and says why")

        // A refresh from the tab list's revision keeps what's being typed; it saves on blur.
        context.evaluateScript(#"""
        const promptBox=control("localSystemPrompt");promptBox.focus();promptBox.value="Be brief and kind";
        replies.push(manifest("r5",{cantripHomeEnabled:true,copilotIdleReleaseMinutes:0,localSystemPrompt:"From another device"}));
        noteMacSettings({supportsSettings:true,settingsRevision:"r5"});
        """#)
        check(#"""
        calls.length===6&&calls[5].method==="GET"&&macSettingsState.data.revision==="r5"&&control("localSystemPrompt").tagName==="TEXTAREA"
          &&control("localSystemPrompt").value==="Be brief and kind"&&document.activeElement===control("localSystemPrompt")
        """#, "A refresh doesn't clobber the text field being typed in")
        context.evaluateScript(#"""
        replies.push(manifest("r6",{cantripHomeEnabled:true,copilotIdleReleaseMinutes:0,localSystemPrompt:"Be brief and kind"}));
        control("localSystemPrompt").onchange();noteMacSettings({supportsSettings:true,settingsRevision:"r6"});
        """#)
        check(#"calls.length===7&&sent(6)==='{"revision":"r5","changes":{"localSystemPrompt":"Be brief and kind"}}'"#,
              "Text saves when committed, and an unchanged revision doesn't reload")

        // A guarded port change waits to be kept; an empty port with a zero label sends 0.
        context.evaluateScript(#"""
        const now={cantripHomeEnabled:true,copilotIdleReleaseMinutes:0,localSystemPrompt:"Be brief and kind"};
        replies.push(manifest("r7",{...now,remoteLANPort:8766},{id:"p1",keys:["remoteLANPort"],summary:"Direct port 8766",secondsLeft:60,revertsAt:"2026-11-02T12:00:00Z"}));
        const port=control("remoteLANPort");port.value="8766";port.onchange();
        """#)
        check(#"""
        sent(7)==='{"revision":"r6","changes":{"remoteLANPort":8766}}'&&!$("macSettingsPending").classList.contains("hidden")
          &&$("macSettingsPendingText").textContent==="Keep Direct port 8766? Undoes in 60 s."&&$("macSettingsStatus").textContent.includes("unless you keep it")
        """#, "A guarded change shows Keep and Undo with a countdown")
        context.evaluateScript(#"replies.push(manifest("r8",{...now,remoteLANPort:8766}));$("macSettingsKeep").onclick();"#)
        check(#"sent(8)==='{"keep":"p1"}'&&$("macSettingsPending").classList.contains("hidden")"#, "Keep posts the pending id")
        context.evaluateScript(#"replies.push(manifest("r9",now));const automatic=control("remoteLANPort");automatic.value=" ";automatic.onchange();"#)
        check(#"sent(9)==='{"revision":"r8","changes":{"remoteLANPort":0}}'"#, "An empty port is its zero label, 0")

        // Secrets: saved and cleared, never shown.
        context.evaluateScript(#"""
        replies.push(manifest("r10",{...now,localAPIKey:true}));control("localAPIKey").value="sk-fixture";byID("macSetting-localAPIKey-save").onclick();
        """#)
        check(#"""
        sent(10)==='{"revision":"r9","changes":{"localAPIKey":"sk-fixture"}}'&&control("localAPIKey").value===""&&text(row("localAPIKey")).includes("Set")
          &&!byID("macSetting-localAPIKey-clear").disabled
        """#, "A secret saves, clears its field and shows that it's set")
        context.evaluateScript(#"replies.push(manifest("r11",now));byID("macSetting-localAPIKey-clear").onclick();"#)
        check(#"sent(11)==='{"revision":"r10","changes":{"localAPIKey":""}}'"#, "Clear sends an empty secret")

        // An action's text to copy shows once, beside it, and survives a refresh until hidden.
        context.evaluateScript(#"""
        replies.push({...manifest("r12",now),result:{message:"Copy the new key now: Cantrip won't show it again.",copy:"proxy-key-fixture"}});control("makeOpenAIEndpointKey").onclick();
        """#)
        check(#"""
        sent(12)==='{"action":"makeOpenAIEndpointKey"}'&&confirms.length===0&&byID("macSetting-makeOpenAIEndpointKey-copy").value==="proxy-key-fixture"
          &&text(row("makeOpenAIEndpointKey")).includes("Cantrip won't show it again")
        """#, "An action's copy text is shown with a Copy button")
        context.evaluateScript(#"replies.push(manifest("r13",now));noteMacSettings({supportsSettings:true,settingsRevision:"r13"});"#)
        check(#"byID("macSetting-makeOpenAIEndpointKey-copy")?.value==="proxy-key-fixture""#, "The copy text stays until hidden")

        // Replace Pairing Token: this browser switches to the new token and keeps the change over it.
        context.evaluateScript(#"""
        replies.push({...manifest("r14",now,{id:"p2",keys:["pairingToken"],summary:"the new pairing token",secondsLeft:60}),
          result:{message:"Replaced. Other devices have to pair again.",pairingToken:"NEWTOKEN-fixture"}});control("rotatePairingToken").onclick();
        """#)
        check(#"""
        confirms[0]==="Every other device has to pair again."&&sent(14)==='{"action":"rotatePairingToken"}'&&calls[14].token==="old-token"
          &&token==="NEWTOKEN-fixture"&&localStorage.cantripToken==="NEWTOKEN-fixture"&&tokenHandoff?.id==="p2"
        """#, "The new pairing token is used and saved at once")
        check(#"""
        ![...all(),...Object.values(elements)].some(item=>[item.text,item.textContent,item.value,JSON.stringify(item.attributes||{})].some(value=>String(value??"").includes("NEWTOKEN")))
        """#, "The pairing token is never shown")
        context.evaluateScript(#"replies.push({status:401,error:"unauthorized"});runTimers(600);"#)
        check(#"sent(15)==='{"keep":"p2"}'&&calls[15].token==="NEWTOKEN-fixture"&&tokenHandoff!==null&&token==="NEWTOKEN-fixture""#,
              "Keep goes over the new token and is retried while the Mac still refuses it")
        context.evaluateScript(#"replies.push(manifest("r15",now));runTimers(1000);"#)
        check(#"""
        sent(16)==='{"keep":"p2"}'&&tokenHandoff===null&&token==="NEWTOKEN-fixture"&&refreshes>0&&$("macSettingsPending").classList.contains("hidden")
          &&$("macSettingsStatus").textContent==="This device stays paired with the new token."
        """#, "Once kept, the new token stays")

        // Undo while switching goes back to the previous token.
        context.evaluateScript(#"""
        replies.push({...manifest("r16",now,{id:"p3",keys:["pairingToken"],summary:"the new pairing token",secondsLeft:60}),result:{pairingToken:"SECOND-fixture"}});
        control("rotatePairingToken").onclick();
        """#)
        check(#"token==="SECOND-fixture"&&tokenHandoff?.id==="p3""#, "A second replacement switches again")
        context.evaluateScript(#"replies.push(manifest("r17",now));$("macSettingsUndo").onclick();"#)
        check(#"""
        sent(18)==='{"revert":"p3"}'&&calls[18].token==="SECOND-fixture"&&token==="NEWTOKEN-fixture"&&localStorage.cantripToken==="NEWTOKEN-fixture"&&tokenHandoff===null
        """#, "Undo restores the token this browser had")
        context.evaluateScript("const before=calls.length;runTimers(600);")
        check("calls.length===before", "An undone switch stops trying to keep it")

        // Older Macs don't offer it; closing ends the sheet.
        context.evaluateScript("noteMacSettings({sessions:[]});")
        check(#"$("tabMacSettings").classList.contains("hidden")"#, "Macs without supportsSettings hide the entry")
        context.evaluateScript(#"noteMacSettings({supportsSettings:true,settingsRevision:"r17"});$("macSettingsDone").onclick();"#)
        check(#"!$("tabMacSettings").classList.contains("hidden")&&!$("macSettingsEditor").open&&macSettingsState===null"#,
              "The entry shows when supported, and Done closes the sheet")
    }
}
