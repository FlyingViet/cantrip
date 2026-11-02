import { describe, expect, it, vi } from "vitest";

// The sheets' kit listens on the page when it loads.
vi.hoisted(() => {
  const noop = () => {};
  const scope = globalThis as Record<string, unknown>;
  scope.document = { addEventListener: noop, removeEventListener: noop, visibilityState: "visible" };
  scope.window = scope;
  scope.addEventListener = noop;
  scope.removeEventListener = noop;
});

import { backendsBridgeRequest } from "../src/main/backendsBridge";
import type { BackendHealth, BackendsAction } from "../src/gateway/api/types";
import { BackendRow } from "../src/gateway/ui/sheets/BackendStatusList";
import {
  BACKENDS_UNSUPPORTED, backendCheckLine, backendLines, backendOffersSignIn, backendSignInLine, backendSignInPending, backendStatus,
  backendsErrorText, backendsPollDelay, backendTime, INVALID_RESPONSE, normalizeBackends,
} from "../src/gateway/ui/sheets/sheetLogic";

// MARK: A small VNode walker (no DOM): components are called with their props, like a shallow render.

interface VNode { type: unknown; props: Record<string, unknown> & { children?: unknown } }
interface Element { tag: string; props: Record<string, unknown>; children: Node[] }
type Node = Element | string;

function isVNode(value: unknown): value is VNode {
  return typeof value === "object" && value !== null && "type" in value && "props" in value;
}

function render(value: unknown): Node[] {
  if (value == null || typeof value === "boolean") return [];
  if (Array.isArray(value)) return value.flatMap(render);
  if (typeof value === "string" || typeof value === "number") return [String(value)];
  if (!isVNode(value)) return [];
  if (typeof value.type === "function") return render((value.type as (props: unknown) => unknown)(value.props));
  const { children, ...props } = value.props;
  return [{ tag: String(value.type), props, children: render(children) }];
}

function text(nodes: Node[]): string {
  return nodes.map((node) => (typeof node === "string" ? node : text(node.children))).join("");
}

function elements(nodes: Node[]): Element[] {
  return nodes.flatMap((node) => (typeof node === "string" ? [] : [node, ...elements(node.children)]));
}

function labelled(nodes: Node[], label: string): Element {
  const found = elements(nodes).find((node) => node.props["aria-label"] === label);
  if (!found) throw new Error(`No control labelled "${label}"`);
  return found;
}

function buttons(nodes: Node[]): string[] {
  return elements(nodes).filter((node) => node.tag === "button").map((node) => node.props["aria-label"] as string);
}

// MARK: Fixtures (GET /api/v1/backends entries)

const NOW = Date.parse("2026-11-01T20:00:00Z");
const terminal = (name: string, command: string) => ({ mode: "terminal", command, hint: `${name} signs in only in Terminal on the Mac.` });
const device = (command: string) => ({ mode: "deviceCode", command, hint: "Sign in shows a link and a code here. Open the link on any device and enter the code." });

const READY: BackendHealth = {
  id: "copilot", name: "Copilot CLI", state: "ready", summary: "Signed in as octocat (GitHub account)",
  path: "/opt/homebrew/bin/copilot", version: "1.0.105", signedIn: true, account: "octocat", authMethod: "GitHub account", plan: "Pro",
  quota: [{ name: "Weekly limit", usedPercent: 42.5, resetsAt: "2026-11-07T02:31:18Z" }, { name: "Premium requests" }],
  lastSuccessAt: "2026-11-01T19:30:00Z", checkedAt: "2026-11-01T19:58:00Z", checking: false, unavailable: false,
  signIn: device("copilot login --device-code"),
};

const SKIPPED = "Skipped by routing: your backups run until you sign in.";

const SIGNED_OUT: BackendHealth = {
  id: "claude", name: "Claude Code", state: "signedOut", summary: SKIPPED,
  path: "/opt/homebrew/bin/claude", version: "2.1.0", signedIn: false, quota: [],
  lastAuthError: { message: "Invalid API key · Please run /login", at: "2026-11-01T19:40:00Z" },
  checkedAt: "2026-11-01T19:41:00Z", checking: false, unavailable: true, problem: "Claude Code isn't signed in.",
  signIn: { ...terminal("Claude Code", "claude auth login"), message: "Finish signing in to Claude Code in Terminal on the Mac." },
};

const DEVICE_PENDING: BackendHealth = {
  id: "codex", name: "Codex", state: "signedOut", summary: SKIPPED,
  signedIn: false, quota: [], checking: false, unavailable: true,
  signIn: {
    ...device("codex login --device-auth"), url: "https://auth.example.com/device", code: "ABCD-1234",
    startedAt: "2026-11-01T19:59:00Z", message: "Open the link on any device and enter the code.",
  },
};

const NOT_INSTALLED: BackendHealth = {
  id: "antigravity", name: "Antigravity", state: "notInstalled", summary: "Not installed on the Mac", quota: [],
  checkedAt: "2026-11-01T19:58:00Z", checking: false, unavailable: false, signIn: terminal("Antigravity", "agy"),
};

const UNKNOWN: BackendHealth = {
  id: "claude", name: "Claude Code", state: "unknown", summary: "Claude Code didn't answer within 45 s.",
  path: "/opt/homebrew/bin/claude", quota: [], checking: true, unavailable: false,
  problem: "Claude Code didn't answer within 45 s.", signIn: terminal("Claude Code", "claude auth login"),
};

const OUT_OF_QUOTA: BackendHealth = {
  id: "codex", name: "Codex", state: "outOfQuota", summary: "Out of quota until 9:00 PM", signedIn: true, account: "person@example.com",
  authMethod: "ChatGPT", quota: [{ name: "5-hour limit", usedPercent: 100, resetsAt: "2026-11-01T21:00:00Z" }],
  limitedUntil: "2026-11-01T21:00:00Z", checking: false, unavailable: false, signIn: device("codex login --device-auth"),
};

function row(backend: BackendHealth, extra: { busy?: boolean; checking?: boolean; copyNote?: string } = {}) {
  const acts: BackendsAction[] = [];
  const opened: string[] = [];
  const copied: string[] = [];
  const nodes = render(BackendRow({
    backend, where: "on the Mac", busy: extra.busy ?? false, checking: extra.checking ?? backend.checking === true,
    copyNote: extra.copyNote, now: NOW, locale: "en-US",
    onAct: (body) => acts.push(body), onOpen: (url) => opened.push(url), onCopy: (code) => copied.push(code),
  }));
  return { nodes, acts, opened, copied };
}

/** The row's live check line ("Checking…", "Checked …"): its last status region. */
function checkLine(nodes: Node[]): Element | undefined {
  return elements(nodes).filter((node) => node.props.role === "status").at(-1);
}

/** The row's one sign-in line (a live region, empty when there's nothing to say). */
function signInLine(nodes: Node[]): Element | undefined {
  return elements(nodes).find((node) => String(node.props.id ?? "").endsWith("-sign-in"));
}

/** The header's state label (the `mcp-status` span). */
function stateLabel(nodes: Node[]): string {
  const label = elements(nodes).find((node) => String(node.props.class).startsWith("mcp-status"));
  return label ? text([label]) : "";
}

function click(nodes: Node[], label: string): void {
  (labelled(nodes, label).props.onClick as () => void)();
}

// MARK: Tests

describe("backend status rows", () => {
  it("names every state in text, toned like an MCP server", () => {
    expect(backendStatus(READY)).toEqual({ text: "Ready", tone: "" });
    expect(backendStatus(SIGNED_OUT)).toEqual({ text: "Signed out", tone: "warning" });
    expect(backendStatus(OUT_OF_QUOTA)).toEqual({ text: "Out of quota", tone: "warning" });
    expect(backendStatus(NOT_INSTALLED)).toEqual({ text: "Not installed", tone: "" });
    expect(backendStatus({ ...UNKNOWN, checking: false })).toEqual({ text: "Unknown", tone: "" });
    expect(backendStatus({ state: "somethingNew" })).toEqual({ text: "Unknown", tone: "" });
    expect(backendStatus(UNKNOWN)).toEqual({ text: "Checking…", tone: "" });
    expect(backendStatus({ ...SIGNED_OUT, checking: true })).toEqual({ text: "Checking…", tone: "" });
  });

  it("shows a ready backend's install, account, quota used with reset time, last run and last check", () => {
    const lines = backendLines(READY, "on the Mac", NOW, "en-US").map((line) => line.text);
    expect(lines[0]).toBe("Signed in as octocat (GitHub account)");
    expect(lines).toContain("Installed: /opt/homebrew/bin/copilot · 1.0.105");
    expect(lines).toContain("Account: octocat · GitHub account · Pro");
    expect(lines).toContain(`Weekly limit: 43% used · resets ${backendTime("2026-11-07T02:31:18Z", NOW, "en-US")}`);
    expect(lines).toContain("Premium requests");
    expect(lines).toContain(`Last successful run: ${backendTime("2026-11-01T19:30:00Z", NOW, "en-US")}`);
    expect(backendCheckLine(READY, NOW, "en-US")).toBe(`Checked ${backendTime("2026-11-01T19:58:00Z", NOW, "en-US")}`);

    const { nodes } = row(READY);
    const shown = text(nodes);
    expect(shown).toContain("Copilot CLI");
    expect(stateLabel(nodes)).toBe("Ready");
    expect(shown).not.toContain("Skipped by routing");
    expect(buttons(nodes)).toEqual(["Check Copilot CLI now"]);
    const section = elements(nodes).find((node) => node.tag === "section");
    expect(section?.props["aria-label"]).toBe("Copilot CLI backend");
  });

  it("reads times as today's time, a weekday within a week, or a full date", () => {
    expect(backendTime("2026-11-01T19:58:00Z", NOW, "en-US")).toBe(new Date("2026-11-01T19:58:00Z").toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" }));
    expect(backendTime("2026-11-04T19:58:00Z", NOW, "en-US")).toMatch(/^(Mon|Tue|Wed|Thu) \d{1,2}:\d{2}\s?[AP]M$/);
    expect(backendTime("2026-10-01T19:58:00Z", NOW, "en-US")).toMatch(/Oct 1, 2026/);
    expect(backendTime("not a date", NOW)).toBeNull();
    expect(backendTime(undefined, NOW)).toBeNull();
  });

  it("offers Sign in to a signed-out backend, says routing skips it and shows the last sign-in error and Terminal hint", () => {
    const { nodes, acts } = row({ ...SIGNED_OUT, signIn: terminal("Claude Code", "claude auth login") });
    const shown = text(nodes);
    expect(stateLabel(nodes)).toBe("Signed out");
    expect(shown.split("Skipped by routing")).toHaveLength(2);
    expect(shown).toContain(SKIPPED);
    expect(shown).toContain(`Last sign-in error: Invalid API key · Please run /login (${backendTime("2026-11-01T19:40:00Z", NOW, "en-US")})`);
    // `problem` is only for a check that couldn't tell.
    expect(shown).not.toContain("Claude Code isn't signed in.");
    expect(buttons(nodes)).toEqual(["Check Claude Code now", "Sign in to Claude Code"]);
    const line = signInLine(nodes);
    expect(text(line ? [line] : [])).toBe("Claude Code signs in only in Terminal on the Mac.");
    expect(line?.props.role).toBe("status");
    expect(labelled(nodes, "Sign in to Claude Code").props["aria-describedby"]).toBe(line?.props.id);
    click(nodes, "Sign in to Claude Code");
    click(nodes, "Check Claude Code now");
    expect(acts).toEqual([{ action: "signIn", id: "claude" }, { action: "check", id: "claude" }]);
  });

  it("shows the sign-in's own message once, in place of the Terminal hint", () => {
    expect(backendSignInLine(SIGNED_OUT)).toBe("Finish signing in to Claude Code in Terminal on the Mac.");
    const { nodes } = row(SIGNED_OUT);
    const shown = text(nodes);
    expect(shown.split("Finish signing in to Claude Code in Terminal on the Mac.")).toHaveLength(2);
    expect(shown).not.toContain("Claude Code signs in only in Terminal on the Mac.");
    expect(text([checkLine(nodes)!])).toBe(`Checked ${backendTime("2026-11-01T19:41:00Z", NOW, "en-US")}`);
    // A device-code backend has no hint to show; a ready one needs no sign-in line.
    expect(backendSignInLine({ ...SIGNED_OUT, signIn: device("codex login --device-auth") })).toBeNull();
    expect(backendSignInLine(READY)).toBeNull();
    expect(backendSignInLine({ ...NOT_INSTALLED })).toBeNull();
    expect(backendSignInLine({ ...READY, signIn: { ...device("copilot login --device-code"), message: "Sign-in cancelled." } })).toBe("Sign-in cancelled.");
  });

  it("shows a pending device sign-in's code with Open link, Copy code and Cancel", () => {
    expect(backendSignInPending(DEVICE_PENDING)).toBe(true);
    expect(backendOffersSignIn(DEVICE_PENDING)).toBe(false);
    const { nodes, acts, opened, copied } = row(DEVICE_PENDING, { copyNote: "Code copied." });
    const code = elements(nodes).find((node) => node.tag === "code");
    expect(code && text([code])).toBe("ABCD-1234");
    expect(String(code?.props.class)).toContain("selectable");
    expect(text(nodes)).toContain("https://auth.example.com/device");
    expect(buttons(nodes)).toEqual(["Check Codex now", "Cancel Codex sign-in", "Copy code for Codex sign-in", "Open link for Codex sign-in"]);
    click(nodes, "Open link for Codex sign-in");
    click(nodes, "Copy code for Codex sign-in");
    click(nodes, "Cancel Codex sign-in");
    expect(opened).toEqual(["https://auth.example.com/device"]);
    expect(copied).toEqual(["ABCD-1234"]);
    expect(acts).toEqual([{ action: "cancelSignIn", id: "codex" }]);
    // The code box carries the instructions: the sign-in's message isn't printed anywhere else.
    expect(text(nodes)).not.toContain("Open the link on any device and enter the code.");
    expect(text(nodes)).toContain("on any device and enter this code:");
    expect(text(nodes)).toContain("Code copied.");
    const status = checkLine(nodes);
    expect(status?.props["aria-live"]).toBe("polite");
    expect(text(status ? [status] : [])).toBe("Not checked yet");
    // Screen readers hear that the code is ready.
    const line = signInLine(nodes);
    expect(text(line ? [line] : [])).toBe("Codex sign-in code ABCD-1234 is ready.");
    expect(elements(line ? [line] : []).some((node) => node.props.class === "sr-only")).toBe(true);
  });

  it("asks for an install instead of a sign-in when the CLI is missing", () => {
    expect(backendOffersSignIn(NOT_INSTALLED)).toBe(false);
    const { nodes } = row(NOT_INSTALLED);
    const shown = text(nodes);
    expect(stateLabel(nodes)).toBe("Not installed");
    expect(shown).toContain("Install Antigravity on the Mac to use it.");
    expect(shown).not.toContain("Installed:");
    expect(buttons(nodes)).toEqual(["Check Antigravity now"]);
  });

  it("says Checking… while a check runs and offers Sign in when the check couldn't tell", () => {
    const { nodes, acts } = row(UNKNOWN);
    expect(text([checkLine(nodes)!])).toBe("Checking…");
    expect(stateLabel(nodes)).toBe("Checking…");
    expect(stateLabel(row({ ...READY, checking: false }, { checking: true }).nodes)).toBe("Checking…");
    expect(labelled(nodes, "Check Claude Code now").props["aria-disabled"]).toBe(true);
    click(nodes, "Check Claude Code now");
    expect(acts).toEqual([]);
    expect(buttons(nodes)).toContain("Sign in to Claude Code");
    expect(backendOffersSignIn({ ...READY, signedIn: false })).toBe(true);
  });

  it("shows `problem` only when a check couldn't tell, and only when the summary doesn't already say it", () => {
    const problems = (backend: BackendHealth) => backendLines(backend, "on the Mac", NOW).filter((line) => line.key === "problem");
    expect(problems(UNKNOWN)).toEqual([]);
    expect(problems({ ...UNKNOWN, summary: "Couldn't check the sign-in" }).map((line) => line.text)).toEqual(["Claude Code didn't answer within 45 s."]);
    for (const backend of [SIGNED_OUT, READY, OUT_OF_QUOTA, NOT_INSTALLED]) {
      expect(problems({ ...backend, problem: "Not logged in" })).toEqual([]);
    }
  });

  it("shows an out-of-quota backend's used-up window without offering a sign-in", () => {
    const { nodes } = row(OUT_OF_QUOTA);
    const shown = text(nodes);
    expect(stateLabel(nodes)).toBe("Out of quota");
    expect(shown).toContain(`5-hour limit: 100% used · resets ${backendTime("2026-11-01T21:00:00Z", NOW, "en-US")}`);
    expect(shown).toContain("Account: person@example.com · ChatGPT");
    expect(buttons(nodes)).toEqual(["Check Codex now"]);
  });

  it("polls fast only while a check or a device sign-in runs", () => {
    expect(backendsPollDelay(null)).toBe(8000);
    expect(backendsPollDelay({ backends: [READY, SIGNED_OUT, NOT_INSTALLED] })).toBe(8000);
    expect(backendsPollDelay({ backends: [READY, UNKNOWN] })).toBe(1500);
    expect(backendsPollDelay({ backends: [READY, DEVICE_PENDING] })).toBe(1500);
  });

  it("asks an older Mac to update and refuses a payload without backends", () => {
    expect(backendsErrorText(Object.assign(new Error("Not found"), { status: 404 }))).toBe(BACKENDS_UNSUPPORTED);
    expect(backendsErrorText(Object.assign(new Error("Method not allowed"), { status: 405 }))).toBe(BACKENDS_UNSUPPORTED);
    expect(BACKENDS_UNSUPPORTED).toBe("Update Cantrip on the Mac to see backend status.");
    expect(backendsErrorText(Object.assign(new Error("Can't reach your Mac."), { status: 502 }))).toBe("Can't reach your Mac.");
    expect(() => normalizeBackends({ servers: [] })).toThrow(INVALID_RESPONSE);
    expect(normalizeBackends({ backends: [READY, { id: 3 }], revision: 12, message: "ok" })).toEqual({ backends: [READY], revision: 12, message: "ok" });
  });
});

describe("Settings' backends bridge", () => {
  it("passes the status and its actions", () => {
    expect(backendsBridgeRequest({ method: "GET" })).toEqual({ method: "GET" });
    expect(backendsBridgeRequest({ method: "POST", body: { action: "check" } })).toEqual({ method: "POST", body: JSON.stringify({ action: "check" }) });
    expect(backendsBridgeRequest({ method: "POST", body: { action: "check", id: "claude" } }))
      .toEqual({ method: "POST", body: JSON.stringify({ action: "check", id: "claude" }) });
    expect(backendsBridgeRequest({ method: "POST", body: { id: "codex", action: "signIn" } }))
      .toEqual({ method: "POST", body: JSON.stringify({ action: "signIn", id: "codex" }) });
    expect(backendsBridgeRequest({ method: "POST", body: { action: "cancelSignIn", id: "antigravity" } })).toHaveProperty("method", "POST");
    expect(backendsBridgeRequest({ method: "POST", body: { action: "check", id: "copilot" } })).toHaveProperty("method", "POST");
  });

  it("refuses anything else", () => {
    expect(backendsBridgeRequest(null)).toHaveProperty("error");
    expect(backendsBridgeRequest({ method: "DELETE" })).toHaveProperty("error");
    expect(backendsBridgeRequest({ method: "GET", body: {} })).toHaveProperty("error");
    expect(backendsBridgeRequest({ method: "POST" })).toHaveProperty("error");
    expect(backendsBridgeRequest({ method: "POST", body: [] })).toHaveProperty("error");
    expect(backendsBridgeRequest({ method: "POST", body: { action: "signOut", id: "codex" } })).toHaveProperty("error");
    expect(backendsBridgeRequest({ method: "POST", body: { action: "signIn" } })).toHaveProperty("error");
    expect(backendsBridgeRequest({ method: "POST", body: { action: "cancelSignIn" } })).toHaveProperty("error");
    expect(backendsBridgeRequest({ method: "POST", body: { action: "signIn", id: "gemini" } })).toHaveProperty("error");
    expect(backendsBridgeRequest({ method: "POST", body: { action: "check", id: "" } })).toHaveProperty("error");
    expect(backendsBridgeRequest({ method: "POST", body: { action: "check", id: "claude", path: "/api/v1/sessions" } })).toHaveProperty("error");
    expect(backendsBridgeRequest({ method: "POST", body: { action: "signIn", id: "codex", token: "x" } })).toHaveProperty("error");
  });
});
