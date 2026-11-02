// The Settings window's way to the Mac's shared MCP servers (GET/POST /api/v1/mcp). It never gets
// the pairing token: the main process checks each request against the list's own actions, then
// sends it with the token. Responses carry state only; credentials stay on the Mac.

export const MCP_BACKENDS = ["Copilot", "Claude Code", "Codex", "Antigravity"] as const;
const SIGN_IN_ACTIONS = new Set(["connect", "approve", "decline", "cancel", "signOut"]);

export interface MCPBridgeRequest {
  method: "GET" | "POST";
  /** JSON for POST. */
  body?: string;
}

/** The request Settings may make, or an error saying what's wrong with it. */
export function mcpBridgeRequest(input: unknown): MCPBridgeRequest | { error: string } {
  if (!input || typeof input !== "object") return { error: "Send a request." };
  const { method, body } = input as { method?: unknown; body?: unknown };
  if (method === "GET") return body === undefined ? { method: "GET" } : { error: "A list request has no body." };
  if (method !== "POST" || !body || typeof body !== "object" || Array.isArray(body)) {
    return { error: "Send GET, or POST with an action." };
  }
  const fields = body as Record<string, unknown>;
  const { action, name, enabled, backend } = fields;
  if (typeof name !== "string" || !name || name.length > 200) return { error: "Name a server." };
  if (typeof action !== "string") return { error: "Choose an action." };
  let keys: string[];
  if (SIGN_IN_ACTIONS.has(action)) keys = ["action", "name"];
  else if (action === "setEnabled") keys = ["action", "name", "enabled"];
  else if (action === "setBackend") keys = ["action", "name", "backend", "enabled"];
  else return { error: `Settings can't send ${action}.` };
  if (Object.keys(fields).sort().join() !== [...keys].sort().join()) return { error: "That request has fields it shouldn't." };
  if (keys.includes("enabled") && typeof enabled !== "boolean") return { error: "Say on or off." };
  if (keys.includes("backend") && !MCP_BACKENDS.includes(backend as (typeof MCP_BACKENDS)[number])) {
    return { error: "Choose Copilot, Claude Code, Codex or Antigravity." };
  }
  return { method: "POST", body: JSON.stringify(fields) };
}
