// The Settings window's way to the Mac's settings manifest (GET/POST /api/v1/settings). Like the MCP and
// backends bridges, it never gets the pairing token: the main process checks each request's shape, then
// sends it with the token. When the window replaces the Mac's pairing token, the reply's new token is
// taken out here, saved for this Mac and kept with the Mac (keepNewToken); the window sees only the message.

export interface SettingsBridgeRequest {
  method: "GET" | "POST";
  /** JSON for POST. */
  body?: string;
}

/** Setting keys (`cantrip config` names), action keys and pending-change IDs. */
const NAME = /^[A-Za-z0-9_.-]{1,128}$/;
/** The Mac refuses larger bodies (SettingsManifest.maximumBody). */
const MAXIMUM_BODY = 65_536;

function isValue(value: unknown): boolean {
  return typeof value === "boolean" || typeof value === "string" || (typeof value === "number" && Number.isFinite(value));
}

/** The request Settings may make, or an error saying what's wrong with it. */
export function settingsBridgeRequest(input: unknown): SettingsBridgeRequest | { error: string } {
  if (!input || typeof input !== "object") return { error: "Send a request." };
  const { method, body } = input as { method?: unknown; body?: unknown };
  if (method === "GET") return body === undefined ? { method: "GET" } : { error: "A settings request has no body." };
  if (method !== "POST" || !body || typeof body !== "object" || Array.isArray(body)) {
    return { error: "Send GET, or POST with changes, an action, keep or revert." };
  }
  const fields = body as Record<string, unknown>;
  const keys = Object.keys(fields).sort().join();
  let checked: Record<string, unknown>;
  if (keys === "changes,revision") {
    const { revision, changes } = fields;
    if (typeof revision !== "string" || !revision || revision.length > 128) return { error: "Send the revision you loaded." };
    if (!changes || typeof changes !== "object" || Array.isArray(changes)) return { error: "Send the changes as an object." };
    const entries = Object.entries(changes as Record<string, unknown>);
    if (!entries.length || entries.length > 100) return { error: "Send 1 to 100 changes." };
    for (const [key, value] of entries) {
      if (!NAME.test(key)) return { error: "That setting's name isn't valid." };
      if (!isValue(value)) return { error: "A setting is on or off, a number or text." };
    }
    checked = { revision, changes: Object.fromEntries(entries) };
  } else if (keys === "action" || keys === "keep" || keys === "revert") {
    const value = fields[keys];
    if (typeof value !== "string" || !NAME.test(value)) return { error: keys === "action" ? "Name an action." : "Name the change." };
    checked = { [keys]: value };
  } else {
    return { error: "That request has fields it shouldn't." };
  }
  const json = JSON.stringify(checked);
  if (Buffer.byteLength(json) > MAXIMUM_BODY) return { error: "That change is too large." };
  return { method: "POST", body: json };
}

/** What the main window's tab-list poll says about the Mac's settings, checked before Settings hears it. */
export function settingsRevisionInfo(input: unknown): { supportsSettings: boolean; settingsRevision: string } | null {
  if (!input || typeof input !== "object") return null;
  const { supportsSettings, settingsRevision } = input as { supportsSettings?: unknown; settingsRevision?: unknown };
  if (typeof supportsSettings !== "boolean" || typeof settingsRevision !== "string" || settingsRevision.length > 128) return null;
  return { supportsSettings, settingsRevision };
}

/** A reply without `result.pairingToken`, which never goes to a window, and that token (null when there's none). */
export function takePairingToken(body: unknown): { body: unknown; token: string | null } {
  const result = (body as { result?: unknown } | null)?.result;
  if (!result || typeof result !== "object" || !("pairingToken" in result)) return { body, token: null };
  const { pairingToken, ...rest } = result as Record<string, unknown>;
  return { body: { ...(body as object), result: rest }, token: typeof pairingToken === "string" ? pairingToken : null };
}

export interface KeepNewTokenDeps {
  /** Sends to /api/v1/settings with the new token: the status and JSON; throws while the Mac can't be reached. */
  send(request: SettingsBridgeRequest): Promise<{ status: number; body: unknown }>;
  sleep(milliseconds: number): Promise<void>;
  now(): number;
}

export type KeepNewTokenOutcome =
  | { kept: true; manifest: unknown }
  /** `undone`: the Mac went back to the old token; `unreachable`: no answer with the new one in time. */
  | { kept: false; reason: "undone" | "unreachable" };

/**
 * Keeps a replaced pairing token (`pending.id`) over the new token, retrying while the Mac switches to it
 * (about half a second after replying; until then it refuses the new token). A 409 means an earlier keep
 * already went through and its answer was lost, or the Mac undid the change: a read with the new token tells.
 */
export async function keepNewToken(
  pendingID: string, deps: KeepNewTokenDeps,
  timing: { firstDelayMs: number; retryMs: number; timeoutMs: number } = { firstDelayMs: 600, retryMs: 700, timeoutMs: 10_000 },
): Promise<KeepNewTokenOutcome> {
  const deadline = deps.now() + timing.timeoutMs;
  await deps.sleep(timing.firstDelayMs);
  for (;;) {
    try {
      const reply = await deps.send({ method: "POST", body: JSON.stringify({ keep: pendingID }) });
      if (reply.status === 200) return { kept: true, manifest: reply.body };
      if (reply.status === 409) {
        const check = await deps.send({ method: "GET" });
        const pending = (check.body as { pending?: { id?: unknown } } | null)?.pending;
        if (check.status === 200 && pending?.id !== pendingID) return { kept: true, manifest: check.body };
        if (check.status === 401) return { kept: false, reason: "undone" };
      }
    } catch { /* the Mac is switching listeners */ }
    if (deps.now() + timing.retryMs > deadline) return { kept: false, reason: "unreachable" };
    await deps.sleep(timing.retryMs);
  }
}
