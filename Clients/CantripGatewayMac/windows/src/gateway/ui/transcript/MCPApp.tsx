// Interactive MCP App views (e.g. Mobbin galleries) in a reply, ported from the host web client:
// each runs in a frame sandboxed to an opaque origin (never allow-same-origin), talking JSON-RPC
// over postMessage; tool calls go through the Mac (POST …/apps/<id>/request).
import type { JSX } from "preact";
import { useEffect, useRef, useState } from "preact/hooks";
import { api, pathComponent } from "../../api/client";
import type { MCPAppPayload, MCPAppServerResponse, MCPAppSummary, MCPAppViewResponse } from "../../api/types";
import { bridge } from "../../bridge";
import { confirmDialog } from "../kit";

const MAX_HEIGHT = 640;
const heights = new Map<string, number>();

function textOf(content: unknown): string {
  const blocks = Array.isArray(content) ? content : content && typeof content === "object" ? [content] : [];
  return (blocks as { type?: string; text?: unknown }[])
    .filter((block) => block?.type === "text" && typeof block.text === "string")
    .map((block) => block.text as string).join("\n\n").trim();
}

function cleanMessage(text: string): string {
  return text.replace(/[\u00AD\u061C\u180E\u200B-\u200F\u202A-\u202E\u2060-\u2064\u2066-\u206F\uFEFF]/g, "")
    .replace(/[^\S\n]+/g, " ").replace(/ *\n\s*\n\s*/g, "\n\n").trim().slice(0, 2000);
}

function externalURL(raw: unknown): string | null {
  try {
    const url = new URL(String(raw));
    return (url.protocol === "https:" || url.protocol === "http:") && url.hostname && !url.username && !url.password ? url.href : null;
  } catch {
    return null;
  }
}

export function MCPAppStack(props: { sessionID: string; apps: MCPAppSummary[] }): JSX.Element {
  return <div class="mcp-stack">{props.apps.map((app) => <MCPAppView key={`${props.sessionID}:${app.id}`} sessionID={props.sessionID} app={app} />)}</div>;
}

function MCPAppView(props: { sessionID: string; app: MCPAppSummary }): JSX.Element {
  const { sessionID, app } = props;
  const key = `${sessionID}:${app.id}`;
  const label = `${app.serverName || "MCP app"} · ${app.title || app.toolName}`;
  const frameRef = useRef<HTMLIFrameElement>(null);
  const [status, setStatus] = useState<string | null>("Loading view…");
  const [src, setSrc] = useState<string | null>(null);
  const [link, setLink] = useState<string | null>(null);
  const [height, setHeight] = useState(heights.get(key) ?? 150);
  const state = useRef({ payload: null as MCPAppPayload | null, initialized: false, sentData: false, loads: 0, stopped: false });
  const base = `/api/v1/sessions/${pathComponent(sessionID)}/apps/${pathComponent(app.id)}`;

  useEffect(() => {
    const current = state.current;
    current.stopped = false;
    (async () => {
      try {
        current.payload = await api<MCPAppPayload>(base);
        const view = await api<MCPAppViewResponse>(`${base}/view`, { method: "POST" });
        if (current.stopped) return;
        setSrc(view.url);
        setStatus(null);
      } catch (error) {
        setStatus(`Could not load this view: ${(error as Error).message}`);
      }
    })();
    return () => { current.stopped = true; };
  }, [base]);

  useEffect(() => {
    const send = (message: Record<string, unknown>) => frameRef.current?.contentWindow?.postMessage({ jsonrpc: "2.0", ...message }, "*");
    const context = (changes: Record<string, unknown>) => {
      if (state.current.initialized && !state.current.stopped) send({ method: "ui/notifications/host-context-changed", params: changes });
    };
    const post = <T,>(path: string, body: unknown) => api<T>(`${base}/${path}`, { method: "POST", body });
    const initialize = () => {
      const payload = state.current.payload!;
      const permissions = Object.fromEntries((payload.permissions ?? []).map((name) => [name, {}]));
      let tool: unknown;
      try { tool = JSON.parse(payload.tool); } catch { tool = { name: payload.toolName, inputSchema: { type: "object" } }; }
      return {
        protocolVersion: "2026-01-26",
        hostInfo: { name: "Cantrip Gateway", version: bridge.version },
        hostCapabilities: {
          openLinks: {}, logging: {}, serverTools: {}, serverResources: {}, message: { text: {} },
          updateModelContext: { text: {}, structuredContent: {} }, sandbox: { csp: payload.csp ?? {}, permissions },
        },
        hostContext: {
          toolInfo: { tool }, theme: "dark", displayMode: "inline", availableDisplayModes: ["inline"],
          containerDimensions: { width: frameRef.current?.clientWidth ?? 600, maxHeight: MAX_HEIGHT },
          locale: navigator.language, timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone, userAgent: "Cantrip Gateway",
          platform: "desktop", deviceCapabilities: { touch: false, hover: true },
          styles: { variables: { "--font-sans": "\"Segoe UI Variable Text\", \"Segoe UI\", system-ui, sans-serif", "--font-mono": "\"Cascadia Mono\", Consolas, monospace" } },
        },
      };
    };
    const onMessage = (event: MessageEvent) => {
      const frame = frameRef.current;
      if (!frame || event.source !== frame.contentWindow) return;
      const message = event.data as { jsonrpc?: string; method?: string; params?: Record<string, unknown>; id?: string | number };
      const current = state.current;
      if (!message || message.jsonrpc !== "2.0" || typeof message.method !== "string" || current.stopped || !current.payload) return;
      const params = message.params && typeof message.params === "object" ? message.params : {};
      const id = message.id;
      if (id === undefined) {
        if (message.method === "ui/notifications/initialized") {
          current.initialized = true;
          if (!current.sentData) {
            current.sentData = true;
            let input = {};
            let result = { content: [] as unknown[] };
            try { input = JSON.parse(current.payload.toolInput); result = JSON.parse(current.payload.toolResult); } catch { /* defaults */ }
            send({ method: "ui/notifications/tool-input", params: { arguments: input } });
            send({ method: "ui/notifications/tool-result", params: result });
          }
        } else if (message.method === "ui/notifications/size-changed" && Number(params.height) > 0) {
          const next = Math.min(MAX_HEIGHT, Math.max(48, Math.ceil(Number(params.height))));
          heights.set(key, next);
          setHeight(next);
        }
        return;
      }
      if (typeof id !== "string" && typeof id !== "number") return;
      const reply = (result: unknown) => send({ id, result });
      const fail = (code: number, text: string) => send({ id, error: { code, message: text } });
      switch (message.method) {
        case "ui/initialize":
          current.initialized = false;
          current.sentData = false;
          reply(initialize());
          break;
        case "ping":
          reply({});
          break;
        case "ui/request-display-mode":
          reply({ mode: "inline" });
          break;
        case "ui/open-link": {
          const url = externalURL(params.url);
          if (!url) { fail(-32602, "Invalid URL"); break; }
          bridge.openExternal(url);
          setLink(url);
          reply({});
          break;
        }
        case "ui/message": {
          const text = cleanMessage(textOf(params.content));
          if ((params.role && params.role !== "user") || !text) { fail(-32602, "Invalid message format"); break; }
          void confirmDialog({
            title: `Send this message from ${app.serverName || "the MCP app"}?`,
            message: `It goes to the model as your next message:\n\n${text}`, confirm: "Send",
          }).then((ok) => {
            if (!ok) { fail(-32000, "Message sending denied"); return; }
            post("message", { text }).then(() => reply({}), (error: Error) => fail(-32000, error.message));
          });
          break;
        }
        case "ui/update-model-context": {
          const parts = [textOf(params.content)];
          const structured = params.structuredContent;
          if (structured && typeof structured === "object" && Object.keys(structured).length) parts.push(JSON.stringify(structured));
          const text = parts.filter(Boolean).join("\n").slice(0, 8000);
          post("context", { text: text || null }).then(() => reply({}), (error: Error) => fail(-32000, error.message));
          break;
        }
        case "tools/call":
        case "tools/list":
        case "resources/read":
          post<MCPAppServerResponse>("request", { method: message.method, params })
            .then((data) => reply(data.result ?? {}), (error: Error) => fail(-32000, error.message));
          break;
        default:
          fail(-32601, `Method not found: ${message.method}`);
      }
    };
    addEventListener("message", onMessage);
    const frame = frameRef.current;
    const observer = frame ? new ResizeObserver(() => context({ containerDimensions: { width: frame.clientWidth, maxHeight: MAX_HEIGHT } })) : null;
    if (frame) observer?.observe(frame);
    return () => { removeEventListener("message", onMessage); observer?.disconnect(); };
  }, [src, base, key, app.serverName]);

  const permissions = state.current.payload?.permissions ?? [];
  return (
    <figure class={`mcp-app${app.prefersBorder === false ? " borderless" : ""}`}>
      <figcaption title={`Interactive view from ${app.serverName || "an MCP server"}, shown in a sandbox`}>{label}</figcaption>
      {src && !status ? (
        <iframe ref={frameRef} src={src} title={`Interactive view: ${label}`} sandbox="allow-scripts allow-forms"
          referrerpolicy="no-referrer" allow={permissions.includes("clipboardWrite") ? "clipboard-write" : undefined}
          style={{ height: `${height}px` }}
          onLoad={() => {
            state.current.loads++;
            if (state.current.loads > 1) {
              state.current.stopped = true;
              setStatus("This view tried to leave its page, so it was closed. Reload the conversation to show it again.");
            }
          }} />
      ) : <div class="mcp-app-status" role="status">{status}</div>}
      {link ? <a class="mcp-app-link" href={link} onClick={(event) => { event.preventDefault(); bridge.openExternal(link); }}>Open {new URL(link).host} ↗</a> : null}
    </figure>
  );
}
