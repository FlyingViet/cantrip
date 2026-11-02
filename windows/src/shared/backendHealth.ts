// Pure rules behind Settings › Backends and backend routing, shared by the main process and the
// renderer. They mirror Cantrip Gateway's rows for the Mac host's GET /api/v1/backends.
import type { BackendHealth, BackendId, BackendState, BackendStatus, BackendsAction } from "./types";

export const BACKEND_IDS: BackendId[] = ["claude", "copilot", "codex", "agy"];

/** Settings › Backends names each backend as Cantrip's host does. */
export const BACKEND_NAMES: Record<BackendId, string> = {
  copilot: "Copilot CLI",
  claude: "Claude Code",
  agy: "Antigravity",
  codex: "Codex",
};

const STATE_LABELS: Record<BackendState, string> = {
  ready: "Ready",
  signedOut: "Signed out",
  outOfQuota: "Out of quota",
  notInstalled: "Not installed",
  unknown: "Unknown",
};

/** The only actions Settings may ask for; anything else is null. */
export function parseBackendsAction(input: unknown): BackendsAction | null {
  if (!input || typeof input !== "object" || Array.isArray(input)) return null;
  const fields = input as Record<string, unknown>;
  const keys = Object.keys(fields).sort().join();
  const { action, id } = fields;
  if (action === "check" && keys === "action") return { action: "check" };
  if (keys !== "action,id" || !BACKEND_IDS.includes(id as BackendId)) return null;
  if (action === "check" || action === "signIn" || action === "cancelSignIn") {
    return { action, id: id as BackendId };
  }
  return null;
}

/** A signed-out backend can't be chosen; routing uses a backup until a check finds it signed in. */
export function withHealth(statuses: BackendStatus[], health: Pick<BackendHealth, "id" | "unavailable">[]): BackendStatus[] {
  return statuses.map((status) =>
    status.available && health.some((entry) => entry.id === status.id && entry.unavailable)
      ? { ...status, available: false, detail: `${status.label} is signed out. Sign in from Settings › Backends.` }
      : status,
  );
}

/** The preferred backend when it's usable, else the first usable backup; null when none is. */
export function routeBackend(
  preferred: string | null,
  statuses: Pick<BackendStatus, "id" | "available">[],
): BackendId | null {
  const usable = statuses.filter((status) => status.available);
  return (usable.find((status) => status.id === preferred) ?? usable[0])?.id ?? null;
}

/** The row's state as text (never color alone) and its tone; "Checking…" while a check runs. */
export function backendStatus(backend: Pick<BackendHealth, "state" | "checking">): { text: string; tone: "" | "warning" } {
  if (backend.checking) return { text: "Checking…", tone: "" };
  return {
    text: STATE_LABELS[backend.state] ?? "Unknown",
    tone: backend.state === "signedOut" || backend.state === "outOfQuota" ? "warning" : "",
  };
}

/** A device sign-in is under way: its link and code (or its start) are showing, with Cancel. */
export function backendSignInPending(backend: Pick<BackendHealth, "signIn">): boolean {
  const signIn = backend.signIn;
  return Boolean(signIn && (signIn.url || signIn.code || signIn.startedAt));
}

/** Sign in is offered when the CLI is signed out, couldn't be checked or says it isn't signed in. */
export function backendOffersSignIn(backend: Pick<BackendHealth, "state" | "signedIn" | "signIn">): boolean {
  if (backend.state === "notInstalled" || !backend.signIn || backendSignInPending(backend)) return false;
  return backend.state === "signedOut" || backend.state === "unknown" || backend.signedIn === false;
}

/** A device sign-in's link and code are showing; their box carries the instructions. */
export function backendShowsCode(backend: Pick<BackendHealth, "signIn">): boolean {
  return Boolean(backend.signIn?.url && backend.signIn.code);
}

/**
 * The row's one sign-in line (as on the Mac and iPhone): none while a code shows, else the sign-in's own
 * message, else the terminal hint while a terminal-only backend needs a sign-in.
 */
export function backendSignInLine(backend: Pick<BackendHealth, "state" | "signedIn" | "signIn">): string | null {
  const signIn = backend.signIn;
  if (!signIn || backendShowsCode(backend)) return null;
  if (signIn.message) return signIn.message;
  return signIn.mode === "terminal" && signIn.hint && backendOffersSignIn(backend) ? signIn.hint : null;
}

/** "8:41 PM" today, "Fri 6:31 PM" within a week either way, else "Oct 30, 2026, 8:41 PM"; null when unreadable. */
export function backendTime(iso: string | undefined, now = Date.now(), locale?: string): string | null {
  const date = iso ? new Date(iso) : null;
  if (!date || Number.isNaN(date.getTime())) return null;
  const time = date.toLocaleTimeString(locale, { hour: "numeric", minute: "2-digit" });
  if (date.toDateString() === new Date(now).toDateString()) return time;
  if (Math.abs(date.getTime() - now) < 6 * 86_400_000) {
    return `${date.toLocaleDateString(locale, { weekday: "short" })} ${time}`;
  }
  return date.toLocaleString(locale, { dateStyle: "medium", timeStyle: "short" });
}

export interface BackendLine {
  key: string;
  text: string;
  tone?: "warning";
}

/** The row's detail lines; `where` is "on this PC". */
export function backendLines(backend: BackendHealth, where: string, now = Date.now(), locale?: string): BackendLine[] {
  const lines: BackendLine[] = [];
  if (backend.summary) lines.push({ key: "summary", text: backend.summary });
  if (backend.state === "notInstalled") {
    lines.push({ key: "install", text: `Install ${backend.name} ${where} to use it.` });
  } else if (backend.path || backend.version) {
    lines.push({ key: "installed", text: `Installed: ${[backend.path, backend.version].filter(Boolean).join(" · ")}` });
  }
  const account = [backend.account, backend.authMethod, backend.plan].filter(Boolean);
  if (account.length) lines.push({ key: "account", text: `Account: ${account.join(" · ")}` });
  backend.quota.forEach((quota, index) => {
    const used =
      typeof quota.usedPercent === "number" && Number.isFinite(quota.usedPercent)
        ? `${Math.round(Math.min(100, Math.max(0, quota.usedPercent)))}% used`
        : null;
    const reset = backendTime(quota.resetsAt, now, locale);
    const parts = [used, reset ? `resets ${reset}` : null].filter(Boolean);
    lines.push({ key: `quota${index}`, text: parts.length ? `${quota.name}: ${parts.join(" · ")}` : quota.name });
  });
  const success = backendTime(backend.lastSuccessAt, now, locale);
  if (success) lines.push({ key: "success", text: `Last successful run: ${success}` });
  if (backend.lastAuthError?.message) {
    const at = backendTime(backend.lastAuthError.at, now, locale);
    lines.push({
      key: "authError",
      text: `Last sign-in error: ${backend.lastAuthError.message}${at ? ` (${at})` : ""}`,
      tone: "warning",
    });
  }
  // Why a check couldn't tell; any other state's summary already says what's wrong.
  if (backend.state === "unknown" && backend.problem && backend.problem !== backend.summary) {
    lines.push({ key: "problem", text: backend.problem, tone: "warning" });
  }
  return lines;
}

/** The row's live status line: "Checking…", "Checked 8:41 PM" or "Not checked yet". */
export function backendCheckLine(
  backend: Pick<BackendHealth, "checking" | "checkedAt">,
  now = Date.now(),
  locale?: string,
): string {
  if (backend.checking) return "Checking…";
  const checked = backendTime(backend.checkedAt, now, locale);
  return checked ? `Checked ${checked}` : "Not checked yet";
}
