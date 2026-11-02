// The Settings window's way to the Mac's backend status (GET/POST /api/v1/backends). Like the MCP bridge,
// it never gets the pairing token: the main process checks each request against the section's own
// actions, then sends it with the token. Responses carry install, sign-in and quota state only.

export const BACKEND_IDS = ["copilot", "claude", "antigravity", "codex"] as const;
const ACTIONS = new Set(["check", "signIn", "cancelSignIn"]);

export interface BackendsBridgeRequest {
  method: "GET" | "POST";
  /** JSON for POST. */
  body?: string;
}

/** The request Settings may make, or an error saying what's wrong with it. */
export function backendsBridgeRequest(input: unknown): BackendsBridgeRequest | { error: string } {
  if (!input || typeof input !== "object") return { error: "Send a request." };
  const { method, body } = input as { method?: unknown; body?: unknown };
  if (method === "GET") return body === undefined ? { method: "GET" } : { error: "A status request has no body." };
  if (method !== "POST" || !body || typeof body !== "object" || Array.isArray(body)) {
    return { error: "Send GET, or POST with an action." };
  }
  const fields = body as Record<string, unknown>;
  const { action, id } = fields;
  if (typeof action !== "string" || !ACTIONS.has(action)) return { error: "Choose check, signIn or cancelSignIn." };
  const keys = Object.keys(fields).sort().join();
  // Only "check" may leave out the backend (it checks them all).
  if (keys !== "action,id" && !(action === "check" && keys === "action")) return { error: "That request has fields it shouldn't." };
  if (keys === "action,id" && !BACKEND_IDS.includes(id as (typeof BACKEND_IDS)[number])) {
    return { error: "Choose Copilot CLI, Claude Code, Antigravity or Codex." };
  }
  return { method: "POST", body: JSON.stringify(action === "check" && id === undefined ? { action } : { action, id }) };
}
