// The sidebar (MacHomeSidebar.swift): Pip, Home's sections, every project tab, and the connection.
import type { JSX } from "preact";
import { useRef, useState } from "preact/hooks";
import type { RemoteSessionSummary } from "../api/types";
import { bridge, shortcut } from "../bridge";
import { now } from "../state/clock";
import { relativeShort, runningTasks, tabRowDetail, workingTabs } from "../state/format";
import * as nav from "../state/nav";
import * as remote from "../state/remote";
import { Icon, StatusIcon } from "./icons";
import { openMenu, Spinner, toast } from "./kit";
import { currentActivity, displayName, resolveMood } from "./pip/mascot";
import { Pip } from "./pip/Pip";
import { mascotName, mascotOutfit } from "./pip/prefs";
import { tabActions } from "./tabActions";
import { voiceState } from "./voice/state";

export function Sidebar(): JSX.Element {
  return (
    <aside class="sidebar" aria-label="Sidebar">
      <div class="sidebar-panel">
        <div class="sidebar-top">
          <button type="button" class="icon-btn" title="Hide Sidebar" aria-label="Hide Sidebar"
            onClick={() => { nav.sidebarHidden.value = true; }}>
            <Icon name="sidebar.left" size={18} />
          </button>
        </div>
        <SidebarHeader />
        <SidebarList />
        <SidebarFooter />
      </div>
    </aside>
  );
}

/** Same mood rules as the iOS Home header, from Home's state even while a tab is open. */
export function homeMood() {
  const home = remote.isHomeSelected.value ? remote.selectedSession.value : remote.homeSummary.value;
  const detail = remote.details.value.get(remote.homeID.value ?? "");
  const transcript = remote.isHomeSelected.value ? detail?.messages ?? [] : [];
  const lastRole = transcript[transcript.length - 1]?.role;
  return resolveMood({
    isConnected: remote.isConnected.value,
    isWorking: home?.isStreaming === true,
    activity: currentActivity(home?.status, transcript),
    isListening: voiceState.value.listening,
    isSpeaking: voiceState.value.speaking,
    needsInput: (home?.pendingInputCount ?? 0) > 0,
    hasProblem: remote.errorMessage.value !== null || (remote.isHomeSelected.value && lastRole === "error"),
  });
}

function SidebarHeader(): JSX.Element {
  const name = displayName(mascotName.value);
  const mood = homeMood();
  return (
    <div class="sidebar-header">
      <button type="button" class="pip-button" title={`Customize ${name}`} aria-label={`${name}, customize the mascot`}
        onClick={() => { nav.sheet.value = { kind: "mascot" }; }}>
        <Pip mood={mood} outfit={mascotOutfit.value} size={88} />
      </button>
      <div class="name">{name}</div>
      <div class="home-label">Cantrip Home</div>
    </div>
  );
}

function sectionBadge(id: nav.Section): number {
  const home = remote.isHomeSelected.value ? remote.selectedSession.value : remote.homeSummary.value;
  if (id === "chat") return home?.isCantripHome ? home.pendingInputCount ?? 0 : 0;
  if (id === "tasks") return runningTasks(remote.homeTasks.value?.tasks);
  return 0;
}

function SidebarList(): JSX.Element {
  const tabs = remote.sessions.value;
  const openID = nav.openTabID.value;
  const working = workingTabs(tabs);
  const hasHome = remote.homeSummary.value !== null || !remote.listed.value;
  const [drag, setDrag] = useState<{ id: string; over: string | null; after: boolean } | null>(null);
  const listRef = useRef<HTMLDivElement>(null);

  const onListKeyDown = (event: KeyboardEvent) => {
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
    const rows = Array.from(listRef.current?.querySelectorAll<HTMLElement>(".sidebar-row") ?? []);
    const index = rows.indexOf(document.activeElement as HTMLElement);
    if (index < 0) return;
    event.preventDefault();
    if (event.altKey) {
      // Alt+Up/Down reorders the focused tab, like the Mac's Move Tab Up/Down.
      const id = (document.activeElement as HTMLElement).dataset.tabId;
      const tabIndex = tabs.findIndex((item) => item.id === id);
      const target = tabs[tabIndex + (event.key === "ArrowUp" ? -1 : 1)];
      if (id && target && tabs[tabIndex].supportsTabReordering) {
        void remote.moveTab(id, target.id, event.key === "ArrowDown").catch((error) => toast(`Move failed: ${error.message}`));
      }
      return;
    }
    const next = rows[index + (event.key === "ArrowDown" ? 1 : -1)];
    if (next) { next.focus(); next.click(); }
  };

  return (
    <div class="sidebar-list" ref={listRef} role="navigation" aria-label="Home and tabs" onKeyDown={onListKeyDown}>
      {hasHome ? nav.SECTIONS.map((item, index) => {
        const badge = sectionBadge(item.id);
        const current = openID === null && nav.section.value === item.id;
        return (
          <button key={item.id} type="button" class="sidebar-row" aria-current={current ? "true" : "false"}
            title={`${item.title} (${shortcut(`Ctrl+${index + 1}`)})`} data-section={item.id}
            onClick={() => nav.showHome(item.id)}>
            <Icon name={item.icon} class="row-icon" />
            <span class="label">{item.title}</span>
            {badge > 0 ? <span class="count">{badge}</span> : null}
          </button>
        );
      }) : <div class="sidebar-empty">Cantrip Home is off on the Mac.</div>}
      <div class="sidebar-section" role="heading" aria-level={2}>
        <span>Tabs · {tabs.length}</span>
        <span class="grow" />
        {working > 0 ? <span class="working">{working} working</span> : null}
        <button type="button" class="icon-btn" title={`New Tab (${shortcut("Ctrl+T")})`} aria-label="New Tab"
          disabled={!remote.listed.value || remote.isMutating.value} onClick={() => void nav.createTab()}>
          <Icon name="plus" size={14} />
        </button>
      </div>
      {tabs.map((session) => (
        <TabRow key={session.id} session={session} current={openID === session.id}
          dragClass={drag && drag.over === session.id && drag.id !== session.id ? (drag.after ? " drop-after" : " drop-before") : drag?.id === session.id ? " dragging" : ""}
          onDragStart={() => setDrag({ id: session.id, over: null, after: false })}
          onDragOver={(after) => setDrag((value) => (value ? { ...value, over: session.id, after } : value))}
          onDrop={() => {
            if (drag && drag.id !== session.id && session.supportsTabReordering) {
              void remote.moveTab(drag.id, session.id, drag.after).catch((error) => toast(`Move failed: ${error.message}. Refresh before trying again.`));
            }
            setDrag(null);
          }}
          onDragEnd={() => setDrag(null)} />
      ))}
      {!tabs.length && remote.listed.value ? <div class="sidebar-empty">No tabs yet</div> : null}
    </div>
  );
}

function TabRow(props: {
  session: RemoteSessionSummary;
  current: boolean;
  dragClass: string;
  onDragStart: () => void;
  onDragOver: (after: boolean) => void;
  onDrop: () => void;
  onDragEnd: () => void;
}): JSX.Element {
  const { session } = props;
  const title = remote.tabTitle(session);
  const detail = tabRowDetail(session);
  const age = session.lastActivityAt ? relativeShort(new Date(session.lastActivityAt * 1000), now.value) : null;
  const status = (session.pendingInputCount ?? 0) > 0
    ? <StatusIcon kind="needsInput" size={15} />
    : session.isStreaming ? <Spinner size="small" tint="tint" /> : <span class="dot gray" />;
  const lock = session.isLocalPrivate ? <Icon name="lock.shield.fill" size={12} /> : session.isLocked ? <Icon name="lock.fill" size={12} /> : null;
  const label = [title, session.isLocalPrivate ? "Self-hosted, saved" : session.isLocked ? "Locked" : null, detail?.text, age && age !== "now" ? `${age} ago` : age ? "just now" : null]
    .filter(Boolean).join(", ");
  return (
    <button type="button" class={`sidebar-row${props.dragClass}`} aria-current={props.current ? "true" : "false"}
      data-tab-id={session.id} title={detail?.text ?? title} aria-label={label}
      draggable={session.supportsTabReordering}
      onClick={() => nav.openTab(session.id)}
      onContextMenu={(event) => { event.preventDefault(); openMenu({ x: event.clientX, y: event.clientY }, tabActions(session), { label: `${title} actions` }); }}
      onDragStart={(event) => {
        event.dataTransfer?.setData("text/plain", `cantrip-tab:${session.id}`);
        if (event.dataTransfer) event.dataTransfer.effectAllowed = "move";
        props.onDragStart();
      }}
      onDragOver={(event) => {
        event.preventDefault();
        const box = (event.currentTarget as HTMLElement).getBoundingClientRect();
        props.onDragOver(event.clientY > box.top + box.height / 2);
      }}
      onDrop={(event) => { event.preventDefault(); props.onDrop(); }}
      onDragEnd={props.onDragEnd}>
      <span class="tab-status" aria-hidden="true">{status}</span>
      <span class="label row" style={{ gap: "3px" }}>{lock}<span class="truncate">{title}</span></span>
      {age ? <span class="age" aria-hidden="true">{age}</span> : null}
    </button>
  );
}

function SidebarFooter(): JSX.Element {
  const connection = remote.connection.value;
  const host = remote.hostStatus.value;
  const connected = connection.state === "connected";
  const where = remote.endpointHost.value;
  const text = connected ? where : connection.state === "connecting" ? "Connecting…" : "Reconnecting…";
  return (
    <div class="sidebar-footer">
      <button type="button" class="connection btn plain" style={{ justifyContent: "flex-start" }}
        title={connected ? `Connected to ${host.server || "your Mac"} · ${host.route}` : connection.message || "Can't reach the Mac"}
        aria-label={`Cantrip server: ${connected ? "Connected" : "Not connected"}, ${where}`}
        onClick={() => bridge.openSettings()}>
        <span class={`dot ${connected ? "green" : "gray"}`} />
        <span class="truncate">{text}</span>
      </button>
      {!connected && connection.state === "reconnecting" ? (
        <button type="button" class="btn link" style={{ justifyContent: "flex-start", fontSize: "12px" }} onClick={() => bridge.openSettings()}>
          <Icon name="antenna.radiowaves.left.and.right" size={14} /> Connection Settings…
        </button>
      ) : null}
    </div>
  );
}
