// The Mac's shared MCP servers (CantripMCPServersView, CantripMCPServers.swift), one section per
// server: its state and sign-in, the page a sign-in waits on with Approve, and switches for the
// server, each backend and the tab it was opened from. Shown by the MCP Servers sheet and by
// Settings > Tools & sign-ins, each with its own way to reach the Mac. Tokens never leave the Mac.
import type { JSX } from "preact";
import { useEffect, useRef, useState } from "preact/hooks";
import type { MCPSnapshot } from "../../api/types";
import { Spinner } from "../kit";
import { errorText, isUnsupported, mcpConnectLabel, mcpKind, mcpStatus } from "./sheetLogic";
// @ts-ignore -- esbuild bundles CSS imports; TypeScript has no "*.css" module declaration.
import "./sheets.css";

export const MCP_BACKENDS = ["Copilot", "Claude Code", "Codex", "Antigravity"];
const ACTIVE = ["connecting", "awaitingApproval", "needsLogin"];

/** How a window reaches GET/POST /api/v1/mcp. Errors carry the HTTP `status` when there is one. */
export interface MCPTransport {
  load(tabID?: string): Promise<MCPSnapshot>;
  act(body: Record<string, unknown>): Promise<MCPSnapshot | null>;
}

export function MCPServerList(props: { transport: MCPTransport; tabID?: string }): JSX.Element {
  const { transport, tabID } = props;
  const [snapshot, setSnapshot] = useState<MCPSnapshot | null>(null);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const alive = useRef(true);
  useEffect(() => () => { alive.current = false; }, []);

  async function load(): Promise<MCPSnapshot | null> {
    try {
      const value = await transport.load(tabID);
      if (alive.current) { setSnapshot(value); setError(""); }
      return value;
    } catch (failure) {
      if (alive.current) setError(isUnsupported(failure) ? "Update and reopen Cantrip on the Mac to manage its shared MCP servers." : errorText(failure));
      return null;
    }
  }

  // Fast while a sign-in is moving, slow otherwise.
  useEffect(() => {
    let timer: ReturnType<typeof setTimeout> | undefined;
    const tick = async () => {
      const value = await load();
      if (!alive.current) return;
      const active = value?.servers.some((server) => ACTIVE.includes(server.state?.phase ?? "")) ?? false;
      timer = setTimeout(tick, active ? 1500 : 8000);
    };
    void tick();
    return () => clearTimeout(timer);
  }, []);

  async function act(body: Record<string, unknown>): Promise<void> {
    setBusy(true);
    try {
      const value = await transport.act(body);
      if (alive.current && value) { setSnapshot(value); setError(""); }
    } catch (failure) {
      if (alive.current) setError(errorText(failure));
    } finally {
      if (alive.current) setBusy(false);
      setTimeout(() => void load(), 600);
    }
  }

  const tabOff = new Set(snapshot?.tabDisabled ?? []);
  return (
    <div class="mcp-list">
      <p class="sh-caption">Every backend on the Mac shares these servers. Sign-ins open in the Mac's agent Chrome; approve them here.</p>
      {error && <p role="alert" class="sh-warning">{error}</p>}
      {!snapshot && !error && <div class="sh-label sh-loading" role="status"><Spinner size="small" /><span>Loading MCP servers…</span></div>}
      {snapshot && snapshot.servers.length === 0 && (
        <p>Cantrip isn't sharing MCP servers yet. Turn it on in Cantrip's Settings &gt; MCP Servers on the Mac.</p>
      )}
      {snapshot?.servers.map((server) => {
        const status = mcpStatus(server);
        const phase = server.state?.phase ?? "";
        const name = server.name;
        return (
          <section key={name} class="mcp-server" aria-label={name}>
            <div class="mcp-head">
              <strong>{name}</strong>
              <span class="sh-secondary">{mcpKind(server)}</span>
              <span class={`mcp-status ${status.tone}`}>{status.text}</span>
              {server.oauth && server.enabled && (
                ACTIVE.includes(phase)
                  ? <button type="button" disabled={busy} onClick={() => void act({ action: "cancel", name })}>Cancel</button>
                  : phase === "ready"
                    ? <button type="button" disabled={busy} onClick={() => void act({ action: "signOut", name })}>Sign Out</button>
                    : <button type="button" class="primary" disabled={busy} onClick={() => void act({ action: "connect", name })}>{mcpConnectLabel(server)}</button>
              )}
            </div>
            {server.state && (ACTIVE.includes(phase) || phase === "failed" || phase === "locked") && (
              <div class="mcp-page">
                {server.state.message && <p class={phase === "failed" || phase === "locked" ? "sh-warning" : "sh-secondary"}>{server.state.message}</p>}
                {server.state.screenshot && (
                  <img alt={`The sign-in page for ${name}${server.state.page ? ` on ${server.state.page.host}` : ""}`}
                    src={`data:image/jpeg;base64,${server.state.screenshot}`} />
                )}
                {phase === "awaitingApproval" && (
                  <div class="mcp-actions">
                    <button type="button" disabled={busy} onClick={() => void act({ action: "decline", name })}>Decline</button>
                    <button type="button" class="primary" disabled={busy} onClick={() => void act({ action: "approve", name })}>Approve</button>
                  </div>
                )}
              </div>
            )}
            <div class="mcp-switches">
              <label><input type="checkbox" checked={server.enabled} disabled={busy}
                onChange={(event) => void act({ action: "setEnabled", name, enabled: (event.target as HTMLInputElement).checked })} /> On</label>
              {server.enabled && MCP_BACKENDS.map((backend) => (
                <label key={backend}><input type="checkbox" checked={!server.disabledBackends.includes(backend)} disabled={busy}
                  onChange={(event) => void act({ action: "setBackend", name, backend, enabled: (event.target as HTMLInputElement).checked })} /> {backend}</label>
              ))}
              {server.enabled && tabID && (
                <label><input type="checkbox" checked={!tabOff.has(name)} disabled={busy}
                  onChange={(event) => void act({ action: "setTab", name, tab: tabID, enabled: (event.target as HTMLInputElement).checked })} /> This tab</label>
              )}
            </div>
          </section>
        );
      })}
    </div>
  );
}
