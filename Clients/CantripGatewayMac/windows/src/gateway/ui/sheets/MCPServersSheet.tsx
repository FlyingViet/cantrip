// MCP Servers (CantripMCPServersView, CantripMCPServers.swift): the servers Cantrip on the Mac shares
// with every backend and their sign-ins. Connect opens the consent page in the Mac's agent Chrome;
// this sheet shows it and approves it. Tokens never leave the Mac.
import { useEffect, useState } from "preact/hooks";
import { api } from "../../api/client";
import type { MCPSnapshot } from "../../api/types";
import * as remote from "../../state/remote";
import { Sheet } from "../kit";
import { Caption, Loading, useAlive } from "./common";
import { errorText, isUnsupported, mcpStatus } from "./sheetLogic";

const BACKENDS = ["Copilot", "Claude Code", "Codex", "Antigravity"];
const ACTIVE = ["connecting", "awaitingApproval", "needsLogin"];

export function MCPServersSheet(props: { tabID?: string; onClose: () => void }) {
  const [snapshot, setSnapshot] = useState<MCPSnapshot | null>(null);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const alive = useAlive();
  const query = props.tabID ? `?tab=${encodeURIComponent(props.tabID)}` : "";

  async function load(): Promise<MCPSnapshot | null> {
    try {
      const value = await api<MCPSnapshot>(`/api/v1/mcp${query}`);
      if (alive.current) { setSnapshot(value); setError(""); }
      return value;
    } catch (failure) {
      if (alive.current) setError(isUnsupported(failure) ? "Update and reopen Cantrip on the Mac to manage its shared MCP servers." : errorText(failure));
      return null;
    }
  }

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
      const value = await remote.mutate(() => api<MCPSnapshot>("/api/v1/mcp", { method: "POST", body }));
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
    <Sheet title="MCP Servers" onClose={props.onClose} width={680} height={640}>
      <Caption>Every backend on the Mac shares these servers. Sign-ins open in the Mac's agent Chrome; approve them here.</Caption>
      {error && <p role="alert" class="sh-warning">{error}</p>}
      {!snapshot && !error && <Loading text="Loading MCP servers…" />}
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
              <span class="sh-secondary">{server.remote ? "Remote" : "Local"}{server.relayed ? " · through Cantrip" : ""}</span>
              <span class={`mcp-status ${status.tone}`}>{status.text}</span>
              {server.oauth && server.enabled && (
                ACTIVE.includes(phase)
                  ? <button type="button" disabled={busy} onClick={() => void act({ action: "cancel", name })}>Cancel</button>
                  : phase === "ready"
                    ? <button type="button" disabled={busy} onClick={() => void act({ action: "signOut", name })}>Sign Out</button>
                    : <button type="button" class="primary" disabled={busy} onClick={() => void act({ action: "connect", name })}>Connect</button>
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
              {server.enabled && BACKENDS.map((backend) => (
                <label key={backend}><input type="checkbox" checked={!server.disabledBackends.includes(backend)} disabled={busy}
                  onChange={(event) => void act({ action: "setBackend", name, backend, enabled: (event.target as HTMLInputElement).checked })} /> {backend}</label>
              ))}
              {server.enabled && props.tabID && (
                <label><input type="checkbox" checked={!tabOff.has(name)} disabled={busy}
                  onChange={(event) => void act({ action: "setTab", name, tab: props.tabID, enabled: (event.target as HTMLInputElement).checked })} /> This tab</label>
              )}
            </div>
          </section>
        );
      })}
    </Sheet>
  );
}
