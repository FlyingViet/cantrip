// The Settings window (MacSettingsView.swift): Connection (saved Macs, add one, pairing links), Tools
// & sign-ins (the Mac's shared MCP servers) and Voice. Runs on the Gateway origin and storage
// partition, so voice settings and the downloaded speech model are shared with the main window.
import { render, type JSX } from "preact";
import { useEffect, useRef, useState } from "preact/hooks";
import "./styles/app.css";
import "./settings.css";
import { Icon } from "./ui/icons";
import type { MCPSnapshot } from "./api/types";
import { ConfirmLayer, confirmDialog, FormRow, FormSection, MenuLayer, openMenu, Spinner, ToastLayer } from "./ui/kit";
import { MCPServerList, type MCPTransport } from "./ui/sheets/MCPServerList";
import { VoiceSettingsPanel } from "./ui/voice/VoiceControls";

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
}

interface Check { route: string; ok: boolean; message: string; milliseconds: number }

interface Form { name: string; url: string; directAddress: string; tailscaleOnly: boolean; token: string }

interface SettingsBridge {
  state(): Promise<State>;
  parseLink(link: string): Promise<{ server: Omit<Form, "token">; token: string } | { error: string }>;
  test(form: Form & { id?: string }): Promise<{ checks: Check[] } | { error: string }>;
  add(form: Form): Promise<{ checks?: Check[]; saved?: boolean; selected?: boolean; error?: string }>;
  select(id: string): Promise<State | { error: string }>;
  remove(id: string): Promise<State | { error: string }>;
  openLog(): Promise<void>;
  /** GET or POST /api/v1/mcp through the main process, which checks the request and adds the token. */
  mcp(request: { method: "GET" } | { method: "POST"; body: Record<string, unknown> }): Promise<{ status: number; body?: unknown; error?: string }>;
  /** Runs GitHub's device sign-in in Cantrip Home, in the main window. */
  githubSignIn(): Promise<{ ok?: boolean; error?: string }>;
  openExternal(url: string): void;
  onStatus(callback: (status: Status) => void): void;
  onServers(callback: (state: State) => void): void;
  onLink(callback: (link: string) => void): void;
}

declare global {
  interface Window { gatewaySettings: SettingsBridge }
}

const settings = window.gatewaySettings;
const emptyForm: Form = { name: "", url: "", directAddress: "", tailscaleOnly: false, token: "" };

async function settingsMCP(request: Parameters<SettingsBridge["mcp"]>[0]): Promise<MCPSnapshot> {
  const reply = await settings.mcp(request);
  if (reply.status >= 300 || reply.error !== undefined) {
    throw Object.assign(new Error(reply.error ?? `The Mac answered with HTTP ${reply.status}.`), { status: reply.status });
  }
  return reply.body as MCPSnapshot;
}

const mcpTransport: MCPTransport = {
  load: () => settingsMCP({ method: "GET" }),
  act: (body) => settingsMCP({ method: "POST", body }),
};

type SettingsTab = "connection" | "tools" | "voice";
const TAB_TITLES: Record<SettingsTab, string> = { connection: "Connection", tools: "Tools & sign-ins", voice: "Voice" };

function SettingsApp(): JSX.Element {
  const [tab, setTab] = useState<SettingsTab>("connection");
  const [state, setState] = useState<State | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [link, setLink] = useState<string | null>(null);

  useEffect(() => {
    void settings.state().then((value) => {
      setState(value);
      if (value.notice) setNotice(value.notice);
      if (value.link) setLink(value.link);
    });
    settings.onServers((value) => setState((previous) => ({ ...previous, ...value })));
    settings.onStatus((status) => setState((previous) => (previous ? { ...previous, status } : previous)));
    settings.onLink((value) => { setTab("connection"); setLink(value); });
    document.documentElement.classList.add(`platform-${navigator.userAgent.includes("Windows") ? "win32" : "darwin"}`);
  }, []);

  return (
    <div class="settings-window">
      <header class="settings-titlebar">
        <div class="settings-title">{TAB_TITLES[tab]}</div>
        <nav class="settings-tabs" role="tablist" aria-label="Settings">
          <button type="button" role="tab" aria-selected={tab === "connection"} class="settings-tab" onClick={() => setTab("connection")}>
            <Icon name="antenna.radiowaves.left.and.right" size={20} /><span>Connection</span>
          </button>
          <button type="button" role="tab" aria-selected={tab === "tools"} class="settings-tab" onClick={() => setTab("tools")}>
            <Icon name="point.3.connected" size={20} /><span>Tools &amp; sign-ins</span>
          </button>
          <button type="button" role="tab" aria-selected={tab === "voice"} class="settings-tab" onClick={() => setTab("voice")}>
            <Icon name="waveform" size={20} /><span>Voice</span>
          </button>
        </nav>
      </header>
      <div class="settings-body" role="tabpanel">
        {tab === "connection"
          ? (state ? <Connection state={state} setState={setState} notice={notice} link={link} clearLink={() => setLink(null)} /> : <Spinner />)
          : tab === "tools"
            ? (state?.selectedID ? <><GitHubSignIn /><MCPServerList transport={mcpTransport} /></> : <p class="callout muted">Pair a Mac on Connection first.</p>)
            : <VoiceSettingsPanel />}
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

/** GitHub on the Mac: Sign In runs GitHub's device sign-in in Cantrip Home, whose chat shows the code. */
function GitHubSignIn(): JSX.Element {
  const [message, setMessage] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  return (
    <FormSection header="Sign-ins" footer="Signs the Mac's GitHub CLI in to github.com with GitHub's device sign-in, for pushes, pull requests and GitHub Builds in every backend. It runs in Cantrip Home, whose chat shows a code to enter at github.com/login/device; no password goes through Cantrip.">
      <FormRow label="GitHub on your Mac">
        <button type="button" class="btn" onClick={() => void settings.githubSignIn().then((reply) => {
          setError(reply.error ?? null);
          setMessage(reply.error ? null : "Started in Cantrip Home: its chat shows GitHub's code.");
        })}>Sign In…</button>
      </FormRow>
      {message ? <FormRow><span class="callout muted" role="status">{message}</span></FormRow> : null}
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
        <FormRow label="Help"><button type="button" class="btn" onClick={() => settings.openExternal("https://github.com/FlyingViet/CantripGatewayMac/tree/main/windows")}>Cantrip Gateway on GitHub</button></FormRow>
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
