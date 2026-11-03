// The Settings window (MacSettingsView.swift): Connection (saved Macs, add one, pairing links), Tools
// & sign-ins (the Mac's backends and shared MCP servers), Voice and Location, with the Mac's own settings
// (its manifest, ui/settings/MacSettings.tsx) at the top of the page with the same id and the pages only the
// Mac has (Models, Home & tabs, Memory, About) among them. Runs on the Gateway origin and storage
// partition, so voice settings and the downloaded speech model are shared with the main window.
import { render, type JSX } from "preact";
import { useEffect, useRef, useState } from "preact/hooks";
import "./styles/app.css";
import "./settings.css";
import { Icon, type IconName } from "./ui/icons";
import { APIError } from "./api/client";
import type { BackendsAction, BackendsSnapshot, GitHubAuth, MCPSnapshot, SettingsManifest, SettingsRequest, SettingsSection } from "./api/types";
import { githubPresentation, githubSignInWaiting } from "./ui/sheets/sheetLogic";
import { ConfirmLayer, confirmDialog, FormRow, FormSection, MenuLayer, openMenu, Spinner, ToastLayer } from "./ui/kit";
import { BackendStatusList, type BackendsTransport } from "./ui/sheets/BackendStatusList";
import { MCPServerList, type MCPTransport } from "./ui/sheets/MCPServerList";
import { VoiceSettingsPanel } from "./ui/voice/VoiceControls";
import { forgetFix, PRECISE_KEY, readFlag, readPosition, SHARE_KEY, writeFlag } from "./state/location";
import { MacSettingsBanner, MacSettingsPage, MacSettingsSectionPage, useMacSettings, type MacSettingsTransport } from "./ui/settings/MacSettings";
import { isEditableTarget, normalizeManifest, settingsBackKey, settingsTabs, type SettingsRevisionInfo } from "./ui/settings/macSettingsLogic";

interface SavedMac {
  id: string;
  name: string;
  customName: string;
  url: string;
  directAddress: string;
  tailscaleOnly: boolean;
  routes: string[];
  tokenSuffix: string;
}

interface Status { connected: boolean; route: string; message: string; server: string }

interface State {
  servers: SavedMac[];
  selectedID: string | null;
  unreadable: number;
  status: Status;
  version: string;
  platform: string;
  link?: string | null;
  notice?: string | null;
  /** From the main window's last tab-list poll; null until it has polled the selected Mac. */
  macSettings?: SettingsRevisionInfo | null;
}

interface Check { route: string; ok: boolean; message: string; milliseconds: number }

interface Form { name: string; url: string; directAddress: string; tailscaleOnly: boolean; token: string }

interface HostReply { status: number; body?: unknown; error?: string }

interface SettingsBridge {
  state(): Promise<State>;
  parseLink(link: string): Promise<{ server: Omit<Form, "token">; token: string } | { error: string }>;
  test(form: Form & { id?: string }): Promise<{ checks: Check[] } | { error: string }>;
  add(form: Form): Promise<{ checks?: Check[]; saved?: boolean; selected?: boolean; error?: string }>;
  select(id: string): Promise<State | { error: string }>;
  remove(id: string): Promise<State | { error: string }>;
  openLog(): Promise<void>;
  /** GET or POST /api/v1/mcp through the main process, which checks the request and adds the token. */
  mcp(request: { method: "GET" } | { method: "POST"; body: Record<string, unknown> }): Promise<HostReply>;
  /** GET or POST /api/v1/backends the same way (check, signIn, cancelSignIn). */
  backends(request: { method: "GET" } | { method: "POST"; body: BackendsAction }): Promise<HostReply>;
  /** GET or POST /api/v1/settings the same way. A replaced pairing token is saved by the app and never comes here. */
  settings(request: { method: "GET" } | { method: "POST"; body: SettingsRequest }): Promise<HostReply>;
  /** Runs GitHub's device sign-in in Cantrip Home, in the main window. */
  githubSignIn(): Promise<{ ok?: boolean; error?: string }>;
  openExternal(url: string): void;
  onStatus(callback: (status: Status) => void): void;
  onServers(callback: (state: State) => void): void;
  onLink(callback: (link: string) => void): void;
  /** The Mac's settings revision moved (or the selected Mac changed: null). */
  onSettingsRevision(callback: (info: SettingsRevisionInfo | null) => void): void;
  /** The mouse's back button, which Windows sends the window as an app command. */
  onBack(callback: () => void): void;
}

declare global {
  interface Window { gatewaySettings: SettingsBridge }
}

const settings = window.gatewaySettings;
const emptyForm: Form = { name: "", url: "", directAddress: "", tailscaleOnly: false, token: "" };

async function hostBody<T>(pending: Promise<HostReply>): Promise<T> {
  const reply = await pending;
  if (reply.status >= 300 || reply.error !== undefined) {
    throw Object.assign(new Error(reply.error ?? `The Mac answered with HTTP ${reply.status}.`), { status: reply.status });
  }
  return reply.body as T;
}

const mcpTransport: MCPTransport = {
  load: () => hostBody<MCPSnapshot>(settings.mcp({ method: "GET" })),
  act: (body) => hostBody<MCPSnapshot>(settings.mcp({ method: "POST", body })),
};

const backendsTransport: BackendsTransport = {
  load: () => hostBody<BackendsSnapshot>(settings.backends({ method: "GET" })),
  act: (body) => hostBody<BackendsSnapshot>(settings.backends({ method: "POST", body })),
  openLink: (url) => settings.openExternal(url),
};

/** A settings reply as the Mac's manifest; a refusal keeps its status and JSON (409 `settings`, 422 `fields`). */
async function manifestBody(pending: Promise<HostReply>): Promise<SettingsManifest> {
  const reply = await pending;
  if (reply.status >= 300 || reply.error !== undefined) {
    throw new APIError(reply.error ?? `The Mac answered with HTTP ${reply.status}.`, reply.status, reply.body);
  }
  const manifest = normalizeManifest(reply.body);
  if (!manifest) throw new APIError("The Mac sent settings this version of Cantrip Gateway can't read.", reply.status);
  return manifest;
}

const macSettingsTransport: MacSettingsTransport = {
  load: () => manifestBody(settings.settings({ method: "GET" })),
  send: (body) => manifestBody(settings.settings({ method: "POST", body })),
  openLink: (url) => settings.openExternal(url),
};

/** This window's own pages, by the ids of iPhone's pages they match (Connection is `macs`). */
const OWN_PAGES = [
  { id: "macs", title: "Connection" },
  { id: "tools", title: "Tools & sign-ins" },
  { id: "voice", title: "Voice" },
  { id: "location", title: "Location" },
];
const PAGE_ICONS: Record<string, IconName> = {
  macs: "antenna.radiowaves.left.and.right", models: "cpu", tools: "point.3.connected", home: "house", memory: "brain",
  voice: "waveform", location: "location", notifications: "bell", appearance: "eye", about: "info.circle",
};

function SettingsApp(): JSX.Element {
  const [tab, setTab] = useState("macs");
  const [state, setState] = useState<State | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [link, setLink] = useState<string | null>(null);
  const [polled, setPolled] = useState<SettingsRevisionInfo | null>(null);
  /** A `link` section open as its own page, with a back button (Windows has no swipe back). */
  const [opened, setOpened] = useState<string | null>(null);
  const tabList = useRef<HTMLElement>(null);
  const backButton = useRef<HTMLButtonElement>(null);
  const goBackRef = useRef<(() => void) | null>(null);

  useEffect(() => {
    void settings.state().then((value) => {
      setState(value);
      setPolled((current) => current ?? value.macSettings ?? null);
      if (value.notice) setNotice(value.notice);
      if (value.link) setLink(value.link);
    });
    settings.onServers((value) => setState((previous) => ({ ...previous, ...value })));
    settings.onStatus((status) => setState((previous) => (previous ? { ...previous, status } : previous)));
    settings.onLink((value) => { setTab("macs"); setLink(value); });
    settings.onSettingsRevision((info) => setPolled(info));
    settings.onBack(() => goBackRef.current?.());
    document.documentElement.classList.add(`platform-${navigator.userAgent.includes("Windows") ? "win32" : "darwin"}`);
  }, []);

  const mac = useMacSettings(macSettingsTransport, {
    server: state?.selectedID ?? null, polled, connected: state?.status.connected ?? false,
  });
  const tabs = settingsTabs(OWN_PAGES, mac.manifest?.pages ?? []);
  const current = tabs.find((item) => item.id === tab) ?? tabs[0];
  const section = opened ? current.page?.sections.find((item) => item.id === opened) ?? null : null;
  const choose = (id: string, focus = false) => {
    setTab(id);
    setOpened(null);
    if (focus) requestAnimationFrame(() => tabList.current?.querySelector<HTMLElement>(`[data-tab="${id}"]`)?.focus());
  };
  const onTabKey = (event: KeyboardEvent) => {
    if (event.altKey) return;
    const index = tabs.findIndex((item) => item.id === current.id);
    const next = event.key === "ArrowRight" ? index + 1 : event.key === "ArrowLeft" ? index - 1
      : event.key === "Home" ? 0 : event.key === "End" ? tabs.length - 1 : null;
    if (next === null) return;
    event.preventDefault();
    choose(tabs[(next + tabs.length) % tabs.length].id, true);
  };

  const open = (item: SettingsSection) => {
    setOpened(item.id);
    requestAnimationFrame(() => backButton.current?.focus());
  };
  const lastBack = useRef(0);
  const goBack = () => {
    // The mouse's back button can arrive twice: as a DOM button and as the window's app command.
    if (!opened || Date.now() - lastBack.current < 400) return;
    lastBack.current = Date.now();
    const row = opened;
    setOpened(null);
    requestAnimationFrame(() => document.querySelector<HTMLElement>(`[data-section-row="${CSS.escape(row)}"]`)?.focus());
  };
  goBackRef.current = section ? goBack : null;
  useEffect(() => {
    if (!section) return;
    const onKey = (event: KeyboardEvent) => {
      const target = event.target instanceof HTMLElement ? event.target : null;
      const action = settingsBackKey({
        key: event.key, altKey: event.altKey, ctrlKey: event.ctrlKey, metaKey: event.metaKey, shiftKey: event.shiftKey,
        defaultPrevented: event.defaultPrevented, editable: isEditableTarget(target as HTMLInputElement | null),
      });
      if (action === "back") { event.preventDefault(); goBack(); }
      else if (action === "endEdit") { event.preventDefault(); target?.blur(); }
    };
    const onMouse = (event: MouseEvent) => {
      if (event.button === 3) { event.preventDefault(); goBack(); }
    };
    window.addEventListener("keydown", onKey);
    window.addEventListener("mouseup", onMouse);
    return () => {
      window.removeEventListener("keydown", onKey);
      window.removeEventListener("mouseup", onMouse);
    };
  }, [section?.id]);

  return (
    <div class="settings-window">
      <header class="settings-titlebar">
        <div class="settings-title">{section ? section.title : current.title}</div>
        <nav ref={tabList} class="settings-tabs" role="tablist" aria-label="Settings" onKeyDown={onTabKey}>
          {tabs.map((item) => (
            <button key={item.id} type="button" role="tab" id={`settings-tab-${item.id}`} data-tab={item.id} class="settings-tab"
              aria-selected={item.id === current.id} aria-controls="settings-panel" tabIndex={item.id === current.id ? 0 : -1}
              onClick={() => choose(item.id)}>
              <Icon name={PAGE_ICONS[item.id] ?? "gearshape"} size={20} /><span>{item.title}</span>
            </button>
          ))}
        </nav>
      </header>
      <div class="settings-body" role="tabpanel" id="settings-panel" aria-labelledby={`settings-tab-${current.id}`}>
        <MacSettingsBanner model={mac} showLoadError={current.id === "macs"} />
        {section ? (
          <>
            <div class="settings-back-row">
              <button ref={backButton} type="button" class="btn plain settings-back" aria-label={`Back to ${current.title}`}
                title={`Back to ${current.title} (Alt+Left)`} onClick={goBack}>
                <Icon name="chevron.left" size={14} />
                <span aria-hidden="true">{current.title}</span>
              </button>
            </div>
            <MacSettingsSectionPage key={section.id} model={mac} section={section} />
          </>
        ) : current.page ? <MacSettingsPage key={current.id} model={mac} page={current.page} onOpen={open} /> : null}
        {current.id === "macs"
          ? (state ? <Connection state={state} setState={setState} notice={notice} link={link} clearLink={() => setLink(null)} /> : <Spinner />)
          : current.id === "tools"
            ? (state?.selectedID
              ? <ToolsPage />
              : <p class="callout muted">Pair a Mac on Connection first.</p>)
            : current.id === "location" ? <LocationSettings />
              : current.id === "voice" ? <VoiceSettingsPanel /> : null}
      </div>
      <MenuLayer />
      <ConfirmLayer />
      <ToastLayer />
    </div>
  );
}

/** Pause Agent (the main window's "hermes.paused", shared through this window's storage). */
function PauseAgent(): JSX.Element {
  const read = (): boolean => { try { return JSON.parse(localStorage.getItem("hermes.paused") ?? "false") === true; } catch { return false; } };
  const [paused, setPaused] = useState(read);
  useEffect(() => {
    const follow = (event: StorageEvent) => { if (event.key === "hermes.paused") setPaused(read()); };
    addEventListener("storage", follow);
    return () => removeEventListener("storage", follow);
  }, []);
  const set = (value: boolean) => {
    localStorage.setItem("hermes.paused", JSON.stringify(value));
    setPaused(value);
  };
  return (
    <FormSection footer={paused ? "Paused. This PC sends nothing until you turn this off or click Resume in chat."
      : "Stops every request from this PC, on every tab, until you turn it off (Ctrl+Shift+P)."}>
      <FormRow label="Pause Agent">
        <input type="checkbox" class="switch" checked={paused} aria-label="Pause Agent"
          onChange={(event) => set((event.target as HTMLInputElement).checked)} />
      </FormRow>
    </FormSection>
  );
}

/** Location (off by default): the main window sends this PC's location with each message while it's on. */
function LocationSettings(): JSX.Element {
  const [share, setShare] = useState(() => readFlag(SHARE_KEY));
  const [precise, setPrecise] = useState(() => readFlag(PRECISE_KEY));
  const [status, setStatus] = useState<string | null>(null);
  const check = (precision: boolean) => {
    setStatus("Finding this PC's location…");
    void readPosition(precision).then((reading) => setStatus("fix" in reading
      ? `Found${precision ? "" : "; it's sent rounded to about 1 km"}. Your Mac names the place in each reply.`
      : reading.error));
  };
  useEffect(() => { if (share) check(precise); }, []);
  const setSharing = (value: boolean) => {
    writeFlag(SHARE_KEY, value);
    forgetFix();
    setShare(value);
    if (value) check(precise); else setStatus("Off. Cantrip uses the Mac's location and says so.");
  };
  const setPrecision = (value: boolean) => {
    writeFlag(PRECISE_KEY, value);
    forgetFix();
    setPrecise(value);
    if (share) check(value);
  };
  return (
    <FormSection footer={`Off by default. While on, each message you send includes this PC's location, rounded to about 1 km unless Precise location is on, and its time zone, so weather and "near me" answers are for where you are. It comes from the Windows Location service only while Cantrip Gateway is open, goes only to your Mac over the paired connection, and isn't saved in Cantrip's memory. While off, Cantrip uses the Mac's location and says so.`}>
      <FormRow label="Share location with messages">
        <input type="checkbox" class="switch" checked={share} aria-label="Share location with messages"
          onChange={(event) => setSharing((event.target as HTMLInputElement).checked)} />
      </FormRow>
      <FormRow label="Precise location">
        <input type="checkbox" class="switch" checked={precise} disabled={!share} aria-label="Precise location"
          onChange={(event) => setPrecision((event.target as HTMLInputElement).checked)} />
      </FormRow>
      {status ? <FormRow><span class="callout muted" role="status" aria-live="polite">{status}</span></FormRow> : null}
    </FormSection>
  );
}

/** Tools & sign-ins: the Mac's backends, its GitHub sign-in (from the same backends poll) and MCP servers. */
function ToolsPage(): JSX.Element {
  const [backends, setBackends] = useState<BackendsSnapshot | null>(null);
  return (
    <>
      <BackendStatusList transport={backendsTransport} onSnapshot={setBackends} />
      <GitHubSignIn github={backends?.github} loaded={backends !== null} />
      <MCPServerList transport={mcpTransport} />
    </>
  );
}

/** GitHub on the Mac: who's signed in there, and Sign In, which runs GitHub's device sign-in in Cantrip Home,
 * whose chat shows the code. */
function GitHubSignIn(props: { github: GitHubAuth | undefined; loaded: boolean }): JSX.Element {
  const [startedAt, setStartedAt] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);
  const shown = githubPresentation(props.github, props.loaded);
  const waiting = githubSignInWaiting(startedAt, props.github?.checkedAt);
  const detail = waiting ? "Started in Cantrip Home: its chat shows GitHub's code." : shown.detail;
  const signIn = () => void settings.githubSignIn().then((reply) => {
    setError(reply.error ?? null);
    if (!reply.error) setStartedAt(Date.now());
  });
  return (
    <FormSection header="Sign-ins" footer="Signs the Mac's GitHub CLI in to github.com with GitHub's device sign-in, for pushes, pull requests and GitHub Builds in every backend. It runs in Cantrip Home, whose chat shows a code to enter at github.com/login/device; no password goes through Cantrip.">
      <FormRow label="GitHub on your Mac">
        <button type="button" class={shown.prominent || waiting ? "btn" : "btn plain"} disabled={!waiting && !shown.buttonEnabled}
          onClick={signIn}>{shown.button}</button>
      </FormRow>
      <FormRow>
        <span class={waiting || !shown.warning ? "callout muted" : "alert-text"} role="status" aria-live="polite"
          data-testid="github-status">{detail}</span>
      </FormRow>
      {error ? <FormRow><span class="alert-text" role="alert"><Icon name="exclamationmark.triangle" size={14} />{error}</span></FormRow> : null}
    </FormSection>
  );
}

function Connection(props: { state: State; setState: (state: State) => void; notice: string | null; link: string | null; clearLink: () => void }): JSX.Element {
  const { state } = props;
  const selected = state.servers.find((server) => server.id === state.selectedID) ?? null;
  const status = state.status;
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [selecting, setSelecting] = useState<string | null>(null);
  return (
    <>
      <FormSection>
        <FormRow class="stack">
          <div class="row headline"><Icon name="antenna.radiowaves.left.and.right" />Connect to Cantrip</div>
          <p class="callout muted settings-p">
            Enter the pairing token from Cantrip's Remote control settings on your Mac. Cantrip Gateway tries the Mac's
            encrypted direct address first, then its HTTPS (Tailscale) URL, and switches back when the faster route returns.
          </p>
        </FormRow>
        <FormRow>
          <span class={`dot ${status.connected && selected ? "green" : "gray"}`} />
          <span class="callout grow" role="status">
            {!selected ? "No Mac selected" : status.connected ? `Connected to ${selected.name} · ${status.route}` : status.message ? `Can't reach ${selected.name}: ${status.message}` : `Connecting to ${selected.name}…`}
          </span>
        </FormRow>
      </FormSection>
      <PauseAgent />
      {props.notice ? <p class="callout settings-notice" role="status">{props.notice}</p> : null}

      <section class="form-section">
        <div class="form-header plain">Cantrip Remote Servers</div>
        <div class="form-group">
          {!state.servers.length ? <FormRow><span class="muted">No saved Macs</span></FormRow> : null}
          {state.servers.map((server) => {
            const isSelected = server.id === state.selectedID;
            const remove = async () => {
              const ok = await confirmDialog({
                title: "Remove server?", confirm: `Remove ${server.name}`, destructive: true,
                message: "Only this saved configuration and its credential will be removed. An active connection to it will disconnect.",
              });
              if (!ok) return;
              const result = await settings.remove(server.id);
              if ("error" in result) setError(result.error); else { setError(null); props.setState({ ...state, ...result }); }
            };
            return (
              <div key={server.id} class="form-row server-row">
                <button type="button" class="server-select" aria-pressed={isSelected} disabled={busy || selecting !== null}
                  title={isSelected ? "Selected" : `Connect to ${server.name}`}
                  onContextMenu={(event) => { event.preventDefault(); openMenu({ x: event.clientX, y: event.clientY }, [{ label: "Remove Server", icon: "trash", destructive: true, onSelect: () => void remove() }]); }}
                  onClick={async () => {
                    if (isSelected) return;
                    setSelecting(server.id);
                    setError(null);
                    const result = await settings.select(server.id);
                    setSelecting(null);
                    if ("error" in result) setError(result.error); else props.setState({ ...state, ...result });
                  }}>
                  <Icon name="server" class="accent" size={20} />
                  <span class="grow col" style={{ gap: "2px" }}>
                    <span>{server.name}</span>
                    <span class="caption muted">{server.routes.join(" · ") || "No route"}</span>
                    {isSelected ? <span class="caption accent">Selected</span> : null}
                  </span>
                  {selecting === server.id ? <Spinner size="small" /> : isSelected ? <Icon name="checkmark.circle" class="accent" size={18} /> : null}
                </button>
                <button type="button" class="icon-btn" aria-label={`Remove ${server.name}`} title="Remove Server" disabled={busy || selecting !== null} onClick={() => void remove()}>
                  <Icon name="trash" size={14} />
                </button>
              </div>
            );
          })}
          {state.unreadable ? (
            <FormRow><span class="alert-text"><Icon name="exclamationmark.triangle" size={14} />{state.unreadable === 1 ? "One saved Mac" : `${state.unreadable} saved Macs`} can't be read on this Windows account. Add it again.</span></FormRow>
          ) : null}
          {error ? <FormRow><span class="alert-text" role="alert"><Icon name="exclamationmark.triangle" size={14} />{error}</span></FormRow> : null}
        </div>
        <div class="form-footer">Click a saved Mac to connect. One Mac is selected at a time. Right-click or use the trash button to remove a configuration; this does not delete work on the Mac.</div>
      </section>

      <AddServer busy={busy} setBusy={setBusy} link={props.link} clearLink={props.clearLink} />

      <FormSection header="This PC" footer={`Cantrip Gateway for Windows ${state.version}. The log records routes and errors only, never tokens or messages.`}>
        <FormRow label="Log file"><button type="button" class="btn" onClick={() => void settings.openLog()}>Show Log File</button></FormRow>
        <FormRow label="Help"><button type="button" class="btn" onClick={() => settings.openExternal("https://github.com/FlyingViet/cantrip/tree/main/Clients/CantripGatewayMac/windows")}>Cantrip Gateway on GitHub</button></FormRow>
      </FormSection>
    </>
  );
}

function AddServer(props: { busy: boolean; setBusy: (busy: boolean) => void; link: string | null; clearLink: () => void }): JSX.Element {
  const [form, setForm] = useState<Form>(emptyForm);
  const [checks, setChecks] = useState<Check[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState<string | null>(null);
  const [linkText, setLinkText] = useState("");
  const [showToken, setShowToken] = useState(false);
  const tokenRef = useRef<HTMLInputElement>(null);
  const addRef = useRef<HTMLButtonElement>(null);
  const set = (change: Partial<Form>) => { setForm({ ...form, ...change }); setSaved(null); };

  const useLink = async (value: string) => {
    setError(null);
    if (!value.trim()) { setError("Paste the pairing link first."); return; }
    const result = await settings.parseLink(value.trim());
    if ("error" in result) { setError(result.error); return; }
    setForm({ ...result.server, token: result.token });
    setLinkText("");
    setSaved(`Filled in ${result.server.name || "the Mac"} from the pairing link. Review it, then choose Add Server.`);
    requestAnimationFrame(() => addRef.current?.focus());
  };
  useEffect(() => {
    if (props.link) { void useLink(props.link); props.clearLink(); }
  }, [props.link]);

  const run = async (action: "test" | "add") => {
    setError(null);
    setSaved(null);
    props.setBusy(true);
    try {
      const result = action === "test" ? await settings.test(form) : await settings.add(form);
      if ("checks" in result && result.checks) setChecks(result.checks);
      if ("error" in result && result.error) {
        setError(result.error);
        if (/token/i.test(result.error)) tokenRef.current?.focus();
      } else if (action === "add") {
        setForm(emptyForm);
        setSaved((result as { selected?: boolean }).selected ? "Server saved and connected." : "Server saved. Select it above to connect.");
      } else {
        const ok = (result as { checks: Check[] }).checks.filter((check) => check.ok).length;
        setSaved(ok ? `${ok} of ${(result as { checks: Check[] }).checks.length} routes connected.` : null);
      }
    } finally {
      props.setBusy(false);
    }
  };

  const disabled = props.busy;
  return (
    <>
      <FormSection header="Pair with a Link" footer={<>On the Mac, run <code>cantrip pair --direct</code> and paste the cantripagent:// link it prints. Opening such a link on this PC fills it in too.</>}>
        <FormRow>
          <input class="text-field grow" type="text" autocomplete="off" spellcheck={false} aria-label="Pairing link" placeholder="cantripagent://pair?…"
            value={linkText} disabled={disabled} onInput={(event) => setLinkText((event.target as HTMLInputElement).value)}
            onKeyDown={(event) => { if (event.key === "Enter") { event.preventDefault(); void useLink(linkText); } }} />
          <button type="button" class="btn" disabled={disabled} onClick={() => void useLink(linkText)}>Use Link</button>
        </FormRow>
      </FormSection>

      <section class="form-section">
        <div class="form-header plain">Add Cantrip Remote</div>
        <div class="form-group">
          <FormRow>
            <input class="text-field grow plain-field" type="text" autocomplete="off" placeholder="Server name (optional)" aria-label="Server name (optional)"
              value={form.name} disabled={disabled} onInput={(event) => set({ name: (event.target as HTMLInputElement).value })} />
          </FormRow>
          <FormRow>
            <input class="text-field grow plain-field" type="url" autocomplete="off" spellcheck={false} placeholder="Tailscale URL (optional)" aria-label="Tailscale URL (optional)"
              value={form.url} disabled={disabled} onInput={(event) => set({ url: (event.target as HTMLInputElement).value })} />
          </FormRow>
          <FormRow>
            <input ref={tokenRef} class="text-field grow plain-field" type={(showToken ? "text" : "password") as "text"} autoComplete="off" spellcheck={false} placeholder="Pairing token" aria-label="Pairing token"
              value={form.token} disabled={disabled} onInput={(event) => set({ token: (event.target as HTMLInputElement).value })} />
            <button type="button" class="btn small" aria-pressed={showToken} onClick={() => setShowToken(!showToken)}>{showToken ? "Hide" : "Show"}</button>
          </FormRow>
          <FormRow>
            <input class="text-field grow plain-field" type="text" autocomplete="off" spellcheck={false} placeholder="Direct address, e.g. 192.168.0.20:8766" aria-label="Direct address"
              title="The Mac's IP address and the encrypted port from its Remote control settings"
              value={form.directAddress} disabled={disabled} onInput={(event) => set({ directAddress: (event.target as HTMLInputElement).value })} />
          </FormRow>
          <FormRow label="Tailscale only (skip local network)">
            <input type="checkbox" class="switch" checked={form.tailscaleOnly} disabled={disabled} aria-label="Tailscale only (skip local network)"
              onChange={(event) => set({ tailscaleOnly: (event.target as HTMLInputElement).checked })} />
          </FormRow>
          <FormRow>
            <button type="button" class="btn" disabled={disabled || !form.token.trim()} onClick={() => void run("test")}><Icon name="bolt" size={14} />Test Connection</button>
            <button ref={addRef} type="button" class="btn primary" disabled={disabled || !form.token.trim()} onClick={() => void run("add")}><Icon name="plus.circle" size={14} />Add Server</button>
            {disabled ? <Spinner size="small" label="Checking the Mac" /> : null}
          </FormRow>
          {checks.length ? (
            <div class="form-row stack" aria-label="Routes">
              {checks.map((check) => (
                <div key={check.route} class="route-check">
                  <span class={check.ok ? "green" : "red"}>{check.ok ? "✓ Connected" : "✕ Not connected"}</span>
                  <span>{check.route}</span>
                  <span class="caption muted">{check.ok ? `Answered in ${check.milliseconds} ms` : check.message}</span>
                </div>
              ))}
            </div>
          ) : null}
          {saved ? <FormRow><span class="caption green row" role="status"><Icon name="checkmark.circle" size={14} />{saved}</span></FormRow> : null}
          {error ? <FormRow><span class="alert-text" role="alert"><Icon name="exclamationmark.triangle" size={14} />{error}</span></FormRow> : null}
        </div>
        <div class="form-footer">
          Use each Mac's own pairing token. The direct address (the Mac's IP and the encrypted port in its Remote control settings; Auto
          changes at each launch unless you pin it) reaches the Mac end-to-end encrypted on your network, or over Tailscale with the Mac's
          Tailscale address. The HTTPS URL is used when the direct address can't be reached. Tokens are encrypted for this Windows account.
          Adding a server does not change your current connection.
        </div>
      </section>
    </>
  );
}

render(<SettingsApp />, document.getElementById("app")!);
