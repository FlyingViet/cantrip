// The Home window (MacHomeWindow.swift): sidebar, toolbar, the detail pane, and every sheet.
import type { JSX } from "preact";
import { useEffect, useState } from "preact/hooks";
import { bridge, type GatewayCommand } from "../bridge";
import { isBusy, startFreshSupport } from "../state/format";
import * as nav from "../state/nav";
import * as remote from "../state/remote";
import { BackgroundSheet } from "./activity/BackgroundSheet";
import { BackgroundTasksSheet } from "./activity/BackgroundTasksSheet";
import { InputRequestsSheet } from "./activity/InputRequestsSheet";
import { QueueSheet } from "./activity/Queue";
import { ArtifactsView } from "./home/ArtifactsView";
import { TasksView } from "./home/TasksView";
import { ConfirmLayer, MenuLayer, Sheet, ToastLayer, toast } from "./kit";
import { MascotCustomization } from "./pip/MascotCustomization";
import { BuildsSheet } from "./sheets/BuildsSheet";
import { MacAccessSheet } from "./sheets/MacAccessSheet";
import { MaintenanceSheet } from "./sheets/MaintenanceSheet";
import { MemorySheet } from "./sheets/MemorySheet";
import { ModelSettingsSheet } from "./sheets/ModelSettingsSheet";
import { RenameSheet } from "./sheets/RenameSheet";
import { SectionNameSheet } from "./sheets/SectionNameSheet";
import { UsageSheet } from "./sheets/UsageSheet";
import { Sidebar } from "./Sidebar";
import { Toolbar } from "./Toolbar";
import { ChatView } from "./transcript/ChatView";
import { ThreadView } from "./transcript/ThreadTags";
import { ImageViewer } from "./viewer";
import { BrowserViewer } from "./transcript/BrowserPreview";
import { VoiceModeSheet } from "./voice/VoiceControls";

export function runCommand(command: GatewayCommand): void {
  switch (command) {
    case "chat": nav.showHome("chat"); break;
    case "tasks": nav.showHome("tasks"); break;
    case "artifacts": nav.showHome("artifacts"); break;
    case "background": nav.showBackground(); break;
    case "newTab": void nav.createTab(); break;
    case "newMessage": nav.openChat(); break;
    case "refresh": void remote.refreshNow(); break;
    case "voiceMode": if (!nav.paused.value && remote.selectedID.value) nav.sheet.value = { kind: "voiceMode" }; break;
    case "togglePause": nav.paused.value = !nav.paused.value; break;
    case "modelSettings": nav.openModelSettings(remote.selectedSession.value); break;
    case "startFresh": {
      const session = remote.selectedSession.value;
      if (nav.openTabID.value && session && startFreshSupport(session) === true && !isBusy(session) && !remote.isMutating.value) {
        void remote.startFresh(session.id).catch((error) => toast(`Start Fresh failed: ${error.message}`));
      }
      break;
    }
    case "usage": nav.sheet.value = { kind: "usage" }; break;
    case "memory": nav.sheet.value = { kind: "memory" }; break;
    case "builds": nav.sheet.value = { kind: "builds" }; break;
    case "mascot": nav.sheet.value = { kind: "mascot" }; break;
    case "toggleTerminal": if (nav.section.value === "chat" || nav.openTabID.value) nav.terminalOpen.value = !nav.terminalOpen.value; break;
  }
}

/** Windows has no menu bar in this window, so the page owns the Mac menu's shortcuts. */
function shortcutCommand(event: KeyboardEvent): GatewayCommand | null {
  const primary = bridge.platform === "darwin" ? event.metaKey : event.ctrlKey;
  if (event.key === "F5") return "refresh";
  if (event.key === "`" && event.ctrlKey && !event.altKey && !event.shiftKey && !event.metaKey) return "toggleTerminal";
  if (!primary || event.altKey) return null;
  const key = event.key.toLowerCase();
  if (event.shiftKey) return key === "v" ? "voiceMode" : key === "p" ? "togglePause" : null;
  return ({ "1": "chat", "2": "tasks", "3": "artifacts", b: "background", t: "newTab", n: "newMessage", r: "refresh", ";": "modelSettings" } as Record<string, GatewayCommand>)[key] ?? null;
}

export function App(): JSX.Element {
  useEffect(() => {
    bridge.onCommand(runCommand);
    // Like macOS, an inactive window shows its selection in gray.
    document.body.classList.toggle("inactive", !bridge.focused);
    bridge.onActive((active) => {
      document.body.classList.toggle("inactive", !active);
      remote.setFrontmost(active);
    });
    const onKey = (event: KeyboardEvent) => {
      if (bridge.platform === "darwin" && event.key !== "F5") return; // the menu bar handles these on macOS
      const command = shortcutCommand(event);
      if (!command) return;
      event.preventDefault();
      runCommand(command);
    };
    addEventListener("keydown", onKey);
    void remote.refreshNow();
    return () => removeEventListener("keydown", onKey);
  }, []);

  return (
    <div class={`window${nav.sidebarHidden.value ? " sidebar-hidden" : ""}`}>
      <Sidebar />
      <main class="detail">
        <Toolbar />
        <Detail />
      </main>
      <SheetHost />
      <ImageViewer />
      <BrowserViewer />
      <ThreadView />
      <MenuLayer />
      <ConfirmLayer />
      <ToastLayer />
    </div>
  );
}

function Detail(): JSX.Element {
  if (nav.openTabID.value) return <ChatView key="tab" isTab />;
  switch (nav.section.value) {
    case "tasks": return <TasksView />;
    case "artifacts": return <ArtifactsView />;
    default: return <ChatView key="home" isTab={false} />;
  }
}

function SheetHost(): JSX.Element | null {
  const sheet = nav.sheet.value;
  if (!sheet) return null;
  const close = () => { nav.sheet.value = null; };
  switch (sheet.kind) {
    case "background": return <BackgroundSheet focusSessionID={sheet.focusSessionID} onClose={close} />;
    case "rename": return <RenameSheet sessionID={sheet.sessionID} onClose={close} />;
    case "sectionName": return <SectionNameSheet sectionID={sheet.sectionID} fileTabID={sheet.fileTabID} onClose={close} />;
    case "modelSettings": return <ModelSettingsSheet sessionID={sheet.sessionID} onClose={close} />;
    case "inputRequests": return <InputRequestsSheet sessionID={sheet.sessionID} onClose={close} />;
    case "macAccess": return <MacAccessSheet onClose={close} />;
    case "usage": return <UsageSheet onClose={close} />;
    case "memory": return <MemorySheet onClose={close} />;
    case "builds": return <BuildsSheet onClose={close} />;
    case "maintenance": return <MaintenanceSheet onClose={close} />;
    case "voiceMode": return <VoiceModeSheet onClose={close} />;
    case "queue": return <QueueSheet sessionID={sheet.sessionID} onClose={close} />;
    case "backgroundTasks": return <BackgroundTasksSheet sessionID={sheet.sessionID} onClose={close} />;
    case "mascot":
      return (
        <Sheet title="Customize Mascot" onClose={close} width={560} height={680}>
          <MascotCustomization onDone={close} />
        </Sheet>
      );
    case "promptReader": return <PromptReader title={sheet.title} text={sheet.text} onClose={close} />;
  }
}

const PAGE = 4000;

/** Long prompts page through 4,000 characters at a time (PromptTextView.swift). */
function PromptReader(props: { title: string; text: string; onClose: () => void }): JSX.Element {
  const [starts, setStarts] = useState<number[]>([0]);
  const start = starts[starts.length - 1];
  const end = Math.min(props.text.length, start + PAGE);
  return (
    <Sheet title={props.title} onClose={props.onClose} width={720} height={640}
      footer={<>
        <button type="button" class="btn" disabled={starts.length === 1} onClick={() => setStarts(starts.slice(0, -1))}>Previous</button>
        <span class="caption muted" style={{ margin: "0 auto" }}>Page {starts.length}</span>
        <button type="button" class="btn" disabled={end >= props.text.length} onClick={() => setStarts([...starts, end])}>Next</button>
        <button type="button" class="btn primary" onClick={props.onClose}>Done</button>
      </>}>
      <pre class="selectable" style={{ whiteSpace: "pre-wrap", font: "13px/1.5 var(--font)", margin: 0 }}>{props.text.slice(start, end)}</pre>
    </Sheet>
  );
}
