// Derived text and counts, ported from the Mac app's shared Hermes rules (see files/ref/API.md §8).
import type { HomeTask, RemoteMessage, RemoteSessionSummary, RemoteSubagent } from "../api/types";

export const APPLE_EPOCH = 978307200;

/** Seconds since 2001 (Swift's default Date encoding) to a JS Date. */
export function appleDate(seconds: number): Date {
  return new Date((seconds + APPLE_EPOCH) * 1000);
}

export function unixDate(seconds: number): Date {
  return new Date(seconds * 1000);
}

/** "now / 5m / 3h / 2d / 4w" (CantripRelativeTime.short). */
export function relativeShort(date: Date, now = Date.now()): string {
  const seconds = Math.max(0, (now - date.getTime()) / 1000);
  if (seconds < 60) return "now";
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h`;
  if (seconds < 604800) return `${Math.floor(seconds / 86400)}d`;
  return `${Math.floor(seconds / 604800)}w`;
}

const relativeFormat = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });

/** "in 52 minutes", "13 hours ago" (RelativeDateTimeFormatter .full). */
export function relativeFull(date: Date, now = Date.now()): string {
  const seconds = (date.getTime() - now) / 1000;
  const abs = Math.abs(seconds);
  if (abs < 60) return seconds >= 0 ? "in a moment" : "just now";
  if (abs < 3600) return relativeFormat.format(Math.round(seconds / 60), "minute");
  if (abs < 86400) return relativeFormat.format(Math.round(seconds / 3600), "hour");
  if (abs < 604800) return relativeFormat.format(Math.round(seconds / 86400), "day");
  if (abs < 2629800) return relativeFormat.format(Math.round(seconds / 604800), "week");
  return relativeFormat.format(Math.round(seconds / 2629800), "month");
}

export function clockTime(date: Date): string {
  return date.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
}

/** "45s", "3m 05s", "1h 02m" (CantripSubagentFormat.elapsedLabel). */
export function elapsed(startedAt: number | undefined, finishedAt: number | undefined, now = Date.now() / 1000): string {
  const seconds = Math.max(0, Math.floor((finishedAt ?? now) - (startedAt ?? now)));
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ${String(seconds % 60).padStart(2, "0")}s`;
  return `${Math.floor(seconds / 3600)}h ${String(Math.floor((seconds % 3600) / 60)).padStart(2, "0")}m`;
}

function nonEmpty(value: string | undefined | null): string | null {
  const trimmed = value?.trim();
  return trimmed ? trimmed : null;
}

/** A tab row's second line (CantripTabRowText.detail). */
export function tabRowDetail(session: RemoteSessionSummary): { text: string; active: boolean } | null {
  if ((session.pendingInputCount ?? 0) > 0) return { text: "Needs your input", active: true };
  if (session.isStreaming) return { text: nonEmpty(session.status) ?? "Working…", active: true };
  const parts: string[] = [];
  if (session.queuedCount > 0) parts.push(`${session.queuedCount} queued`);
  const preview = nonEmpty(session.preview);
  if (preview) parts.push(preview);
  else if (session.isLocalPrivate) parts.push("Self-hosted, saved");
  else {
    const status = nonEmpty(session.status);
    if (status) parts.push(status);
  }
  return parts.length ? { text: parts.join(" · "), active: false } : null;
}

/** Working, Needs input, Idle… for a tab's toolbar subtitle (CantripTabRowText.state). */
export function tabState(session: RemoteSessionSummary | null, connection: "connecting" | "connected" | "reconnecting"): string {
  if (connection === "reconnecting") return "Reconnecting…";
  if (connection === "connecting") return "Connecting…";
  if (!session) return "Idle";
  if ((session.pendingInputCount ?? 0) > 0) return "Needs input";
  if (session.isStreaming) return "Working";
  if (session.queuedCount > 0) return `${session.queuedCount} queued`;
  return "Idle";
}

/** undefined: older Mac (disabled with a note); false: hidden; true: available. */
export function startFreshSupport(session: RemoteSessionSummary | null | undefined): boolean | undefined {
  if (!session) return false;
  return session.isCantripHome ? false : session.supportsStartFresh;
}

export function isBusy(session: RemoteSessionSummary | null | undefined): boolean {
  return Boolean(session && (session.isStreaming || session.queuedCount > 0));
}

/** Queued, running or waiting; an unknown status counts as working, like the Mac. */
export function subagentLive(agent: RemoteSubagent): boolean {
  return agent.status !== "completed" && agent.status !== "failed" && agent.status !== "cancelled";
}

/** Running background subagents in a transcript (build/upload watchers). */
export function liveBackgroundSubagents(messages: RemoteMessage[]): RemoteSubagent[] {
  return messages.flatMap((message) => (message.subagents ?? []).filter((agent) => agent.background && subagentLive(agent)));
}

/** Running foreground subagents, pinned above the composer. */
export function liveForegroundSubagents(messages: RemoteMessage[]): RemoteSubagent[] {
  return messages.flatMap((message) => (message.subagents ?? []).filter((agent) => !agent.background && subagentLive(agent)));
}

/** Home toolbar Background count (CantripHomeBackgroundCount.active). */
export function homeBackgroundActive(home: (RemoteSessionSummary & { messages?: RemoteMessage[] }) | null): number {
  if (!home?.isCantripHome) return 0;
  return liveBackgroundSubagents(home.messages ?? []).length + Math.max(0, home.backgroundActiveCount ?? 0);
}

export function workingTabs(sessions: RemoteSessionSummary[]): number {
  return sessions.filter((session) => session.isStreaming).length;
}

export function runningTasks(tasks: HomeTask[] | undefined): number {
  return (tasks ?? []).filter((task) => task.state === "running").length;
}

export function homeNoun(count: number, singular: string, plural?: string): string {
  return count === 1 ? singular : plural ?? `${singular}s`;
}

/** "~/Coding/Plexa" for the Mac's home folder paths. */
export function abbreviatePath(path: string): string {
  return path.replace(/^\/Users\/[^/]+(?=\/|$)/, "~");
}

export function formatBytes(bytes: number | undefined): string {
  if (bytes === undefined || !(bytes >= 0)) return "";
  const units = ["bytes", "KB", "MB", "GB"];
  let value = bytes;
  let unit = 0;
  while (value >= 1000 && unit < units.length - 1) { value /= 1000; unit++; }
  return unit ? `${value < 10 ? value.toFixed(1) : Math.round(value)} ${units[unit]}` : `${bytes} ${bytes === 1 ? "byte" : "bytes"}`;
}

export function compactTokens(value: number): string {
  if (value < 1000) return String(value);
  if (value < 1e6) return value < 1e5 ? `${(value / 1000).toFixed(1)}k` : `${Math.round(value / 1000)}k`;
  return `${(value / 1e6).toFixed(1)}M`;
}
