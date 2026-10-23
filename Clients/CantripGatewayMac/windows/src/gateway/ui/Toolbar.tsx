// The unified toolbar (MacHomeWindow.swift): title + subtitle, then Home's or the open tab's controls.
import type { JSX } from "preact";
import { DELIVERY_MODES, type DeliveryMode } from "../api/types";
import { bridge, shortcut } from "../bridge";
import { abbreviatePath, homeBackgroundActive, isBusy, tabState } from "../state/format";
import * as nav from "../state/nav";
import * as remote from "../state/remote";
import { Icon } from "./icons";
import { MenuButton, toast, type MenuEntry } from "./kit";
import { startFreshEntry, tabActions } from "./tabActions";

export const DELIVERY_TITLES: Record<DeliveryMode, string> = { auto: "Auto", queue: "Queue", interrupt: "Redirect", inject: "Inject" };

function title(): string {
  if (nav.openTabID.value) return remote.tabTitle(remote.selectedSession.value);
  return nav.SECTIONS.find((item) => item.id === nav.section.value)?.title ?? "Chat";
}

function subtitle(): string {
  // Tasks and Artifacts have only a title on the Mac.
  if (!nav.openTabID.value && nav.section.value !== "chat") return "";
  if (nav.paused.value) return "Agent paused";
  const session = remote.selectedSession.value;
  const connection = remote.connection.value;
  if (nav.openTabID.value) {
    const state = tabState(session, connection.state);
    return session?.workdir ? `${state} · ${abbreviatePath(session.workdir)}` : state;
  }
  if (nav.section.value === "chat" && session?.isStreaming) return session.status?.trim() || "Working…";
  if (connection.state === "connected") return remote.endpointHost.value;
  return connection.state === "connecting" ? "Connecting…" : "Reconnecting…";
}

export function Toolbar(): JSX.Element {
  const tab = nav.openTabID.value !== null;
  return (
    <header class="toolbar">
      {nav.sidebarHidden.value ? (
        <button type="button" class="glass-btn" title="Show Sidebar" aria-label="Show Sidebar" onClick={() => { nav.sidebarHidden.value = false; }}>
          <Icon name="sidebar.left" size={18} />
        </button>
      ) : null}
      <div class="toolbar-title">
        <h1>{title()}</h1>
        {subtitle() ? <div class="subtitle">{subtitle()}</div> : null}
      </div>
      {tab ? <TabToolbar /> : <HomeToolbar />}
    </header>
  );
}

function DeliveryPicker(props: { disabled?: boolean }): JSX.Element {
  const mode = nav.deliveryMode.value;
  return (
    <MenuButton label="Delivery" class="glass-btn delivery-pill" title="Delivery: how a message reaches a working tab" disabled={props.disabled} align="end"
      entries={() => [
        { kind: "header", label: "Delivery" },
        ...DELIVERY_MODES.map((value): MenuEntry => ({
          label: DELIVERY_TITLES[value], checked: value === nav.deliveryMode.value, onSelect: () => { nav.deliveryMode.value = value; },
        })),
      ]}>
      <span>{DELIVERY_TITLES[mode]}</span>
      <Icon name="chevron.down" size={12} />
    </MenuButton>
  );
}

function RefreshButton(): JSX.Element {
  const refreshing = remote.isRefreshing.value;
  return (
    <button type="button" class="glass-btn" title={`Refresh Cantrip Home (${shortcut("Ctrl+R")})`} aria-label="Refresh"
      disabled={refreshing} onClick={() => void remote.refreshNow()}>
      <Icon name="arrow.clockwise" size={16} class={refreshing ? "spinning" : undefined} />
    </button>
  );
}

/** Background-run requests waiting on the user (same rule as iOS Home's header). */
export function backgroundInputCount(): number {
  const session = remote.selectedSession.value;
  if (!session?.isCantripHome) return 0;
  return session.backgroundInputCount ?? remote.homeBackground.value?.runs.filter(remote.needsInput).length ?? 0;
}

export function backgroundActiveCount(): number {
  const session = remote.selectedDetail.value ?? remote.selectedSession.value;
  return homeBackgroundActive(session as Parameters<typeof homeBackgroundActive>[0]);
}

function BackgroundButton(): JSX.Element {
  const active = backgroundActiveCount();
  const inputs = backgroundInputCount();
  const value = inputs > 0
    ? `${inputs} ${inputs === 1 ? "needs" : "need"} your input${active > 0 ? `, ${active} running` : ""}`
    : active === 0 ? "Nothing running" : `${active} running`;
  return (
    <button type="button" class="glass-btn" title={`Background tasks and scheduled runs (${shortcut("Ctrl+B")})`}
      aria-label={`Background, ${value}`} data-id="home.background" onClick={() => nav.showBackground()}>
      <Icon name="gearshape.2" size={18} class={active > 0 ? "pulse tint-active" : undefined} />
      {inputs > 0 ? <span class="badge" aria-hidden="true">?</span> : active > 0 ? <span class="badge" aria-hidden="true">{active > 9 ? "9+" : active}</span> : null}
    </button>
  );
}

function HomeToolbar(): JSX.Element {
  const session = remote.selectedSession.value;
  const chat = nav.section.value === "chat";
  return (
    <>
      <div class="glass-group">
        <BackgroundButton />
        {chat && session ? <DeliveryPicker disabled={remote.isMutating.value} /> : null}
        <RefreshButton />
      </div>
      <div class="glass-group">
        <MenuButton label={nav.paused.value ? "More — agent paused" : "More"} entries={homeMoreMenu}>
          <Icon name={nav.paused.value ? "pause.circle" : "ellipsis.circle"} size={18} />
          <Icon name="chevron.down" size={12} />
        </MenuButton>
      </div>
      {!chat ? (
        <div class="glass-group">
          <button type="button" class="glass-btn" aria-label={nav.section.value === "tasks" ? "New Task" : "New Artifact"}
            title={nav.section.value === "tasks" ? "Ask Cantrip Home to track or schedule something" : "Ask Cantrip Home to create something"}
            onClick={() => nav.openChat(nav.section.value === "tasks" ? "Create a task to " : "Create a ")}>
            <Icon name="plus" size={18} />
          </button>
        </div>
      ) : null}
    </>
  );
}

function StopButton(): JSX.Element | null {
  const session = remote.selectedSession.value;
  const stopping = remote.stoppingID.value !== null && remote.stoppingID.value === session?.id;
  if (!session || (!session.isStreaming && !stopping)) return null;
  const enabled = session.isStreaming && remote.isConnected.value && !remote.isMutating.value && !stopping;
  return (
    <button type="button" class="glass-btn stop-btn" disabled={!enabled} aria-label={stopping ? "Stopping Cantrip prompt" : "Stop current Cantrip prompt"}
      title="Stops work on this tab and clears its queued prompts. Keeps the conversation."
      onClick={() => void remote.stop(session.id).catch((error) => toast(`Stop failed: ${error.message}`))}>
      {stopping ? <span class="spinner small" /> : <Icon name="stop.fill" size={12} class="filled" />}
      <span>{stopping ? "Stopping…" : "Stop"}</span>
    </button>
  );
}

function TabToolbar(): JSX.Element {
  const session = remote.selectedSession.value;
  return (
    <>
      <div class="glass-group">
        <StopButton />
        {session ? <DeliveryPicker disabled={remote.isMutating.value} /> : null}
      </div>
      <div class="glass-group">
        <MenuButton label={nav.paused.value ? "Tab actions — agent paused" : "Tab actions"} entries={tabMoreMenu}>
          <Icon name={nav.paused.value ? "pause.circle" : "ellipsis.circle"} size={18} />
          <Icon name="chevron.down" size={12} />
        </MenuButton>
      </div>
    </>
  );
}

function commonEntries(): MenuEntry[] {
  const configured = remote.listed.value;
  return [
    { label: "Copilot Usage", icon: "gauge.with.dots.needle.33percent", disabled: !configured, onSelect: () => { nav.sheet.value = { kind: "usage" }; } },
    {
      label: nav.paused.value ? "Resume Agent" : "Pause Agent", icon: nav.paused.value ? "play.circle" : "pause.circle", shortcut: shortcut("Ctrl+Shift+P"),
      onSelect: () => { nav.paused.value = !nav.paused.value; },
    },
    {
      label: "Voice Mode", icon: "waveform", shortcut: shortcut("Ctrl+Shift+V"),
      disabled: nav.paused.value || !configured || !remote.selectedID.value,
      onSelect: () => { nav.sheet.value = { kind: "voiceMode" }; },
    },
  ];
}

function settingsEntries(): MenuEntry[] {
  return [
    { label: "Connection Settings…", icon: "gearshape", shortcut: shortcut("Ctrl+,"), onSelect: () => bridge.openSettings() },
    { label: "Show Log File", icon: "doc.text", onSelect: () => bridge.showLog() },
  ];
}

export function homeMoreMenu(): MenuEntry[] {
  const session = remote.selectedSession.value;
  const entries: MenuEntry[] = [];
  if (session) {
    entries.push({
      label: "Model Settings…", icon: "slider.horizontal.3", shortcut: shortcut("Ctrl+;"), disabled: remote.isMutating.value,
      onSelect: () => nav.openModelSettings(session),
    });
    entries.push(...startFreshEntry(session));
  }
  entries.push(...commonEntries(), { kind: "separator" },
    { label: "GitHub Builds", icon: "hammer", onSelect: () => { nav.sheet.value = { kind: "builds" }; } },
    { label: "Cantrip Memory", icon: "brain", onSelect: () => { nav.sheet.value = { kind: "memory" }; } },
    { label: "Customize Mascot", icon: "tshirt", onSelect: () => { nav.sheet.value = { kind: "mascot" }; } },
    { kind: "header", label: "Cantrip Mac" },
    { label: "Mac Permissions & View Mac", icon: "desktopcomputer", disabled: !remote.listed.value, onSelect: () => { nav.sheet.value = { kind: "macAccess" }; } },
    { label: "Update & Rebuild Cantrip", icon: "arrow.clockwise", disabled: !remote.listed.value, onSelect: () => { nav.sheet.value = { kind: "maintenance" }; } },
    { kind: "separator" },
    ...settingsEntries());
  return entries;
}

export function tabMoreMenu(): MenuEntry[] {
  const session = remote.selectedSession.value;
  const entries: MenuEntry[] = [];
  if (session && remote.sessions.value.some((item) => item.id === session.id)) {
    entries.push(...tabActions(session), { kind: "separator" });
  }
  if (session?.canResume) {
    entries.push({
      label: "Resume", icon: "play", disabled: remote.isMutating.value || isBusy(session),
      onSelect: () => void remote.resume(session.id).catch((error) => toast(`Resume failed: ${error.message}`)),
    });
  }
  entries.push(
    { label: "Refresh", icon: "arrow.clockwise", shortcut: shortcut("Ctrl+R"), disabled: remote.isRefreshing.value, onSelect: () => void remote.refreshNow() },
    ...commonEntries(),
    { kind: "separator" },
    { label: "Back to Home", icon: "house", onSelect: () => nav.showHome() },
    ...settingsEntries(),
  );
  return entries;
}
