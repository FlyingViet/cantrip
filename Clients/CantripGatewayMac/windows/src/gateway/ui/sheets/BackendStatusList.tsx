// Backends (BackendStatus.swift): each agent CLI on the Mac with its install, sign-in (account and method,
// never a token), quota used and reset times, last good run, last sign-in error and last check, with
// Check now and Sign in (a device link and code shown here, or Terminal on the Mac) and Cancel. Checks
// make no model calls. Rows reuse the MCP servers' StatusRow; the rows are plain props so tests render them.
import type { JSX } from "preact";
import { useEffect, useRef, useState } from "preact/hooks";
import { BACKEND_IDS, type BackendHealth, type BackendID, type BackendsAction, type BackendsSnapshot } from "../../api/types";
import { Spinner } from "../kit";
import {
  backendCheckLine, backendLines, backendOffersSignIn, backendShowsCode, backendSignInLine, backendSignInPending, backendStatus,
  backendsErrorText, backendsPollDelay, normalizeBackends,
} from "./sheetLogic";
import { StatusRow } from "./StatusRow";
// @ts-ignore -- esbuild bundles CSS imports; TypeScript has no "*.css" module declaration.
import "./sheets.css";

/** How a window reaches GET/POST /api/v1/backends (errors carry the HTTP `status`), and opens a sign-in link. */
export interface BackendsTransport {
  load(): Promise<BackendsSnapshot>;
  act(body: BackendsAction): Promise<BackendsSnapshot>;
  openLink(url: string): void;
}

export function BackendStatusList(props: { transport: BackendsTransport }): JSX.Element {
  const { transport } = props;
  const [snapshot, setSnapshot] = useState<BackendsSnapshot | null>(null);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState<BackendsAction | null>(null);
  /** "Code copied." per backend. Action replies' messages aren't shown: each row's sign-in state says what's next. */
  const [copyNotes, setCopyNotes] = useState<Record<string, string>>({});
  const alive = useRef(true);
  const latest = useRef<BackendsSnapshot | null>(null);
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);

  function show(value: BackendsSnapshot): void {
    latest.current = value;
    setSnapshot(value);
    setError("");
  }

  function fail(failure: unknown): void {
    setError(backendsErrorText(failure));
  }

  async function load(): Promise<void> {
    try {
      const value = normalizeBackends(await transport.load());
      if (alive.current) show(value);
    } catch (failure) {
      if (alive.current) fail(failure);
    }
  }

  function schedule(delay: number): void {
    clearTimeout(timer.current);
    if (alive.current) timer.current = setTimeout(() => void tick(), delay);
  }

  // Polls only while this section is on screen: fast while a check or a device sign-in runs.
  async function tick(): Promise<void> {
    if (document.visibilityState !== "hidden") await load();
    schedule(backendsPollDelay(latest.current));
  }

  useEffect(() => {
    void tick();
    const visible = () => { if (document.visibilityState === "visible") void tick(); };
    document.addEventListener("visibilitychange", visible);
    return () => {
      alive.current = false;
      clearTimeout(timer.current);
      document.removeEventListener("visibilitychange", visible);
    };
  }, []);

  function note(id: string, message: string): void {
    setCopyNotes((shown) => ({ ...shown, [id]: message }));
  }

  async function act(body: BackendsAction): Promise<void> {
    if (busy) return;
    setBusy(body);
    if (body.id) note(body.id, "");
    try {
      const value = normalizeBackends(await transport.act(body));
      if (!alive.current) return;
      show(value);
    } catch (failure) {
      if (alive.current) fail(failure);
    } finally {
      if (alive.current) {
        setBusy(null);
        schedule(backendsPollDelay(latest.current));
      }
    }
  }

  async function copy(backend: BackendHealth, code: string): Promise<void> {
    try {
      await navigator.clipboard.writeText(code);
      note(backend.id, "Code copied.");
    } catch {
      note(backend.id, "Couldn't copy: select the code and press Ctrl+C.");
    }
  }

  const checkingAll = busy?.action === "check" && !busy.id;
  return (
    <section class="form-section backends" aria-labelledby="backends-heading">
      <h2 id="backends-heading" class="form-header be-heading">Backends</h2>
      <div class="mcp-list">
        <div class="be-intro">
          <p class="sh-caption">The agent CLIs on the Mac: whether each is installed and signed in, and its quota. Checks make no model calls and use no quota.</p>
          {snapshot && snapshot.backends.length > 0 && (
            <button type="button" class="btn be-button" aria-label="Check all backends now" aria-disabled={busy !== null}
              onClick={() => void act({ action: "check" })}>Check all</button>
          )}
        </div>
        {error && <p role="alert" class="sh-warning">{error}</p>}
        {!snapshot && !error && <div class="sh-label sh-loading" role="status"><Spinner size="small" /><span>Loading backends…</span></div>}
        {snapshot?.backends.map((backend) => (
          <BackendRow key={backend.id} backend={backend} where="on the Mac" copyNote={copyNotes[backend.id]}
            busy={busy !== null} checking={backend.checking === true || checkingAll || (busy?.action === "check" && busy.id === backend.id)}
            onAct={(body) => void act(body)} onOpen={(url) => transport.openLink(url)} onCopy={(code) => void copy(backend, code)} />
        ))}
      </div>
    </section>
  );
}

/** One backend: its state as text, details, a device code while one is pending, and its buttons. */
export function BackendRow(props: {
  backend: BackendHealth;
  /** "on the Mac" or "on this PC". */
  where: string;
  busy: boolean;
  checking: boolean;
  /** Whether Copy code worked. */
  copyNote?: string;
  now?: number;
  locale?: string;
  onAct: (body: BackendsAction) => void;
  onOpen: (url: string) => void;
  onCopy: (code: string) => void;
}): JSX.Element {
  const { backend, busy, checking } = props;
  const now = props.now ?? Date.now();
  const name = backend.name;
  const id = (BACKEND_IDS as readonly string[]).includes(backend.id) ? backend.id as BackendID : null;
  const signIn = backend.signIn;
  const pending = backendSignInPending(backend);
  const offersSignIn = backendOffersSignIn(backend);
  const showsCode = backendShowsCode(backend);
  const signInLine = backendSignInLine(backend);
  const signInID = `backend-${backend.id}-sign-in`;
  const actions = id && (
    <>
      <button type="button" class="btn be-button" aria-label={`Check ${name} now`} aria-disabled={busy || checking}
        onClick={() => { if (!busy && !checking) props.onAct({ action: "check", id }); }}>Check now</button>
      {(pending || offersSignIn) && (
        <button type="button" class={`btn be-button${pending ? "" : " primary"}`} aria-disabled={busy}
          aria-label={pending ? `Cancel ${name} sign-in` : `Sign in to ${name}`} aria-describedby={!pending && signInLine ? signInID : undefined}
          onClick={() => { if (!busy) props.onAct({ action: pending ? "cancelSignIn" : "signIn", id }); }}>
          {pending ? "Cancel" : "Sign in"}
        </button>
      )}
    </>
  );
  return (
    <StatusRow name={name} label={`${name} backend`} status={backendStatus({ ...backend, checking })} actions={actions}>
      {backendLines(backend, props.where, now, props.locale).map((line) => (
        <p key={line.key} class={`be-line selectable ${line.tone === "warning" ? "sh-warning" : "sh-secondary"}`}>{line.text}</p>
      ))}
      <p id={signInID} class="sh-caption be-sign-in" role="status" aria-live="polite">
        {signInLine ?? (showsCode && <span class="sr-only">{name} sign-in code {signIn?.code} is ready.</span>)}
      </p>
      {showsCode && signIn?.url && signIn.code && (
        <div class="be-device">
          <p class="be-line">Open <span class="selectable">{signIn.url}</span> on any device and enter this code:</p>
          <code class="be-code selectable">{signIn.code}</code>
          <div class="mcp-actions">
            <button type="button" class="btn be-button" aria-label={`Copy code for ${name} sign-in`}
              onClick={() => props.onCopy(signIn.code ?? "")}>Copy code</button>
            <button type="button" class="btn primary be-button" aria-label={`Open link for ${name} sign-in`}
              onClick={() => props.onOpen(signIn.url ?? "")}>Open link</button>
          </div>
          <p class="sh-caption be-status" role="status" aria-live="polite">{props.copyNote}</p>
        </div>
      )}
      <p class="sh-caption be-status" role="status" aria-live="polite">
        {checking ? "Checking…" : backendCheckLine(backend, now, props.locale)}
      </p>
    </StatusRow>
  );
}
