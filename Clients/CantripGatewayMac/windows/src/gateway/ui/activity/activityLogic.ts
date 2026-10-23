// Pure rules behind the activity views, ported from CantripSubagentMonitor.swift (CantripSubagentFormat,
// CantripPinnedSubagents, CantripBackgroundTaskButton), CantripHomeBackground.swift (run rows),
// CantripHomeHandoff.swift (handoff cards), CantripHomeView.swift (CantripHomeRunSummaryText) and
// CantripQueueView.swift / PromptTextView.swift. Dates: subagents and handoffs use UnixSeconds;
// background runs and queued runs use AppleReferenceSeconds.
import type {
  HomeBackgroundHandoff, HomeBackgroundQueuedRun, HomeBackgroundRun, HomeBackgroundSnapshot, InputDecision, InputRequest,
  RemoteMessage, RemoteSubagent,
} from "../../api/types";

export const APPLE_EPOCH = 978307200;

// MARK: Text helpers

export function trimmed(value: string | null | undefined): string {
  return (value ?? "").trim();
}

/** Foundation's `String.capitalized`: each word (split at spaces and hyphens) gets one capital. */
export function capitalized(value: string): string {
  return value.toLowerCase().replace(/(^|[\s\-_.])(\p{L})/gu, (_, gap: string, letter: string) => gap + letter.toUpperCase());
}

// MARK: Durations (CantripSubagentFormat)

export function elapsedSeconds(startedAt: number | undefined, finishedAt: number | undefined, now: number): number {
  if (startedAt === undefined || startedAt === null) return 0;
  const end = finishedAt ?? now;
  return Math.max(0, Math.floor(end - startedAt));
}

/** "45s", "3m 05s", "1h 02m". `now` uses the same epoch as the dates. */
export function elapsedLabel(startedAt: number | undefined, finishedAt: number | undefined, now: number): string {
  const seconds = elapsedSeconds(startedAt, finishedAt, now);
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ${String(seconds % 60).padStart(2, "0")}s`;
  return `${Math.floor(seconds / 3600)}h ${String(Math.floor((seconds % 3600) / 60)).padStart(2, "0")}m`;
}

const plural = (count: number, one: string, many: string) => `${count} ${count === 1 ? one : many}`;

/** "3 minutes 5 seconds" for screen readers. */
export function elapsedAccessibilityLabel(startedAt: number | undefined, finishedAt: number | undefined, now: number): string {
  const seconds = elapsedSeconds(startedAt, finishedAt, now);
  if (seconds < 60) return plural(seconds, "second", "seconds");
  if (seconds < 3600) {
    const minutes = Math.floor(seconds / 60);
    const remainder = seconds % 60;
    return remainder === 0 ? plural(minutes, "minute", "minutes") : `${plural(minutes, "minute", "minutes")} ${plural(remainder, "second", "seconds")}`;
  }
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  return minutes === 0 ? plural(hours, "hour", "hours") : `${plural(hours, "hour", "hours")} ${plural(minutes, "minute", "minutes")}`;
}

export function tokenLabel(tokens: number): string {
  const value = Math.max(0, tokens || 0);
  if (value < 1000) return `${value} tokens`;
  if (value < 1e6) return `${(value / 1000).toFixed(1)}k tokens`;
  return `${(value / 1e6).toFixed(1)}M tokens`;
}

export function tokenAccessibilityLabel(tokens: number): string {
  const value = Math.max(0, tokens || 0);
  if (value < 1000) return `${value} tokens`;
  if (value < 1e6) return `${(value / 1000).toFixed(1)} thousand tokens`;
  return `${(value / 1e6).toFixed(1)} million tokens`;
}

export function stepLabel(count: number): string {
  return plural(Math.max(0, count || 0), "step", "steps");
}

// MARK: Subagents

/** The Mac maps unknown statuses to "working": live, not cancellable. */
export type SubagentState = "queued" | "running" | "idle" | "completed" | "failed" | "cancelled" | "working";

export const QUEUED_HINT = "Starts when the main agent waits for it or finishes its turn.";

export function subagentState(agent: Pick<RemoteSubagent, "status">): SubagentState {
  switch (agent.status) {
    case "queued": case "running": case "idle": case "completed": case "failed": case "cancelled": return agent.status;
    default: return "working";
  }
}

export function isLive(agent: Pick<RemoteSubagent, "status">): boolean {
  const state = subagentState(agent);
  return state === "queued" || state === "running" || state === "idle" || state === "working";
}

export function isCancellableState(agent: Pick<RemoteSubagent, "status">): boolean {
  const state = subagentState(agent);
  return state === "queued" || state === "running" || state === "idle";
}

const STATUS_TEXT: Record<SubagentState, string> = {
  queued: "Queued", running: "Running", idle: "Waiting", completed: "Done", failed: "Failed", cancelled: "Stopped", working: "Working",
};

export function subagentStatusText(agent: Pick<RemoteSubagent, "status">): string {
  return STATUS_TEXT[subagentState(agent)];
}

export function subagentDisplayName(agent: Pick<RemoteSubagent, "name" | "agentType">): string {
  const name = trimmed(agent.name);
  if (name) return name;
  const type = trimmed(agent.agentType);
  return type ? capitalized(type) : "Subagent";
}

/** Stop shows for queued, running or idle agents the backend can stop alone, in a known session. */
export function canStopSubagent(agent: RemoteSubagent, sessionID: string | null | undefined): boolean {
  return isCancellableState(agent) && agent.canCancel === true && trimmed(sessionID) !== "";
}

export function subagentSummaryLine(agent: RemoteSubagent): string | null {
  const summary = trimmed(agent.summary);
  return summary && summary !== subagentDisplayName(agent) ? summary : null;
}

/** "Now: …" — the latest reasoning step title, else the intent (running agents only). */
export function subagentCurrentWork(agent: RemoteSubagent): string | null {
  if (subagentState(agent) !== "running") return null;
  const reasoning = trimmed(agent.reasoning?.[agent.reasoning.length - 1]?.title);
  if (reasoning) return reasoning;
  return trimmed(agent.intent) || null;
}

/** "model · 3m 05s · 1.2k tokens". `now` is UnixSeconds. */
export function subagentMetaLine(agent: RemoteSubagent, now: number): string {
  const parts: string[] = [];
  const model = trimmed(agent.model);
  if (model) parts.push(model);
  parts.push(elapsedLabel(agent.startedAt, agent.finishedAt, now));
  parts.push(tokenLabel(agent.tokens));
  return parts.join(" · ");
}

export function subagentAccessibilityLabel(agent: RemoteSubagent, now: number): string {
  const type = trimmed(agent.agentType);
  return [
    type ? `${capitalized(type)} subagent` : "Subagent",
    subagentDisplayName(agent),
    subagentStatusText(agent).toLowerCase(),
    elapsedAccessibilityLabel(agent.startedAt, agent.finishedAt, now),
    tokenAccessibilityLabel(agent.tokens),
  ].join(", ");
}

/** "Latest 6 of 14 steps" / "3 steps" for the recent tool steps disclosure. */
export function recentStepsTitle(agent: RemoteSubagent): string {
  const shown = agent.recentSteps?.length ?? 0;
  return agent.steps > shown ? `Latest ${shown} of ${agent.steps} steps` : stepLabel(shown);
}

/** More than three cards: live ones stay, finished ones fold into "N finished". */
export function stackLayout(subagents: RemoteSubagent[]): { primary: RemoteSubagent[]; finished: RemoteSubagent[] } {
  if (subagents.length <= 3) return { primary: subagents, finished: [] };
  return { primary: subagents.filter(isLive), finished: subagents.filter((agent) => !isLive(agent)) };
}

export function allSubagents(messages: RemoteMessage[] | undefined): RemoteSubagent[] {
  return (messages ?? []).flatMap((message) => message.subagents ?? []);
}

/** Every background subagent (live and finished) in a transcript. */
export function backgroundSubagents(messages: RemoteMessage[] | undefined): RemoteSubagent[] {
  return allSubagents(messages).filter((agent) => agent.background);
}

export function liveBackgroundSubagents(messages: RemoteMessage[] | undefined): RemoteSubagent[] {
  return backgroundSubagents(messages).filter(isLive);
}

export function liveForegroundSubagents(messages: RemoteMessage[] | undefined): RemoteSubagent[] {
  return allSubagents(messages).filter((agent) => isLive(agent) && !agent.background);
}

// MARK: Background task button

export function activeBackground(subagents: RemoteSubagent[]): RemoteSubagent[] {
  return subagents.filter((agent) => agent.background && isLive(agent));
}

export function backgroundTaskIcon(active: RemoteSubagent[]): "spinner" | "clock" | "paused" {
  if (active.some((agent) => subagentState(agent) === "running" || subagentState(agent) === "working")) return "spinner";
  if (active.every((agent) => subagentState(agent) === "queued")) return "clock";
  return "paused";
}

export function backgroundTaskTitle(count: number): string {
  return `${count} background ${count === 1 ? "task" : "tasks"}`;
}

/** "name · Running · 3m 05s" for the lead task. */
export function backgroundTaskSummary(active: RemoteSubagent[], now: number): string {
  const lead = active[0];
  if (!lead) return "";
  return `${subagentDisplayName(lead)} · ${subagentStatusText(lead)} · ${elapsedLabel(lead.startedAt, lead.finishedAt, now)}`;
}

export function backgroundTaskAccessibilityLabel(active: RemoteSubagent[], now: number): string {
  const lead = active[0];
  if (!lead) return "No background tasks";
  return [
    backgroundTaskTitle(active.length), subagentDisplayName(lead), subagentStatusText(lead),
    elapsedAccessibilityLabel(lead.startedAt, lead.finishedAt, now),
  ].join(", ");
}

export function backgroundTasksStatusLine(tasks: RemoteSubagent[]): string {
  const active = tasks.filter(isLive).length;
  if (active === 0) return "All background tasks have finished.";
  return `${active} ${active === 1 ? "task is" : "tasks are"} still running.`;
}

// MARK: Relative dates ("13 hours ago", "yesterday", "last week")

function startOfDay(date: Date): Date {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate());
}

function calendarDays(from: Date, to: Date): number {
  return Math.round((startOfDay(to).getTime() - startOfDay(from).getTime()) / 86400000);
}

function startOfWeek(date: Date): Date {
  const day = startOfDay(date);
  day.setDate(day.getDate() - day.getDay());
  return day;
}

/** Foundation's `.relative(presentation: .named)`: rounded seconds/minutes/hours, then calendar days, weeks, months, years. */
export function relativeNamed(date: Date, now: number, locale?: string): string {
  const format = new Intl.RelativeTimeFormat(locale, { numeric: "auto" });
  const delta = (date.getTime() - now) / 1000;
  const sign = delta < 0 ? -1 : 1;
  const abs = Math.abs(delta);
  const seconds = Math.round(abs);
  if (seconds < 60) return format.format(sign * seconds, "second");
  const minutes = Math.round(abs / 60);
  if (minutes < 60) return format.format(sign * minutes, "minute");
  const hours = Math.round(abs / 3600);
  if (hours < 24) return format.format(sign * hours, "hour");
  const nowDate = new Date(now);
  const [earlier, later] = sign < 0 ? [date, nowDate] : [nowDate, date];
  const days = Math.max(1, calendarDays(earlier, later));
  if (days < 7) return format.format(sign * days, "day");
  const months = (later.getFullYear() - earlier.getFullYear()) * 12 + later.getMonth() - earlier.getMonth();
  if (days < 28 || months === 0) {
    const weeks = Math.max(1, Math.round((startOfWeek(later).getTime() - startOfWeek(earlier).getTime()) / 604800000));
    return format.format(sign * weeks, "week");
  }
  if (months < 12) return format.format(sign * Math.max(1, months), "month");
  return format.format(sign * Math.max(1, later.getFullYear() - earlier.getFullYear()), "year");
}

// MARK: Background runs (CantripHomeBackgroundRun / CantripHomeBackgroundRunRow)

export function appleToUnix(seconds: number): number {
  return seconds + APPLE_EPOCH;
}

export function runIsRunning(run: HomeBackgroundRun): boolean {
  return run.status === "running";
}

export function runIsHandedOff(run: HomeBackgroundRun): boolean {
  return run.route === "tab";
}

export function runTabHandoff(run: HomeBackgroundRun): HomeBackgroundHandoff | null {
  return runIsHandedOff(run) ? run.handoffs?.[run.handoffs.length - 1] ?? null : null;
}

export function runNeedsInput(run: HomeBackgroundRun): boolean {
  return runIsRunning(run) && ((run.inputs ?? []).length > 0 || run.activity === "Needs your input");
}

/** Running hidden runs waiting on the user, answered in place through their own session. */
export function needsInputRuns(snapshot: HomeBackgroundSnapshot | null | undefined): HomeBackgroundRun[] {
  return (snapshot?.runs ?? []).filter((run) => runNeedsInput(run) && Boolean(run.sessionID));
}

export function otherRuns(snapshot: HomeBackgroundSnapshot | null | undefined): HomeBackgroundRun[] {
  const waiting = new Set(needsInputRuns(snapshot).map((run) => run.id));
  return (snapshot?.runs ?? []).filter((run) => !waiting.has(run.id));
}

/** The sheet polls every 2 s while a run waits on the user, else every 5 s. */
export function backgroundPollDelay(snapshot: HomeBackgroundSnapshot | null | undefined): number {
  return needsInputRuns(snapshot).length ? 2000 : 5000;
}

export function remainingInputs(run: HomeBackgroundRun, answered: ReadonlySet<string>): InputRequest[] {
  return (run.inputs ?? []).filter((request) => !answered.has(request.id));
}

export function runStatusText(run: HomeBackgroundRun): string {
  switch (run.status) {
    case "running": return "Running";
    case "succeeded": return "Done";
    case "failed": return "Failed";
    case "cancelled": return "Stopped";
    case "interrupted": return "Interrupted";
    case "skipped": return "Skipped";
    default: return capitalized(run.status);
  }
}

/** A live run's activity, else its finished summary. */
export function runResult(run: HomeBackgroundRun, sharedActivity?: string): string {
  if (runIsRunning(run)) return trimmed(run.activity ?? sharedActivity) || "Running…";
  return trimmed(run.summary);
}

/** A run handed to a tab shows its handoff card instead of repeating its status. */
export function runShowsResult(run: HomeBackgroundRun, sharedActivity?: string): boolean {
  return runResult(run, sharedActivity) !== "" && !runIsHandedOff(run);
}

export function runCanExpand(run: HomeBackgroundRun, sharedActivity?: string): boolean {
  const result = runResult(run, sharedActivity);
  return runShowsResult(run, sharedActivity) && !runIsRunning(run) && ([...result].length > 120 || result.includes("\n"));
}

export function runTabTitle(run: HomeBackgroundRun): string | null {
  const handoff = runTabHandoff(run);
  if (!handoff) return null;
  return trimmed(handoff.tabTitle) || "its project tab";
}

function repeatsText(repeats: number | undefined): string {
  return (repeats ?? 0) > 0 ? ` · reported ${(repeats ?? 0) + 1} times` : "";
}

/** "Scheduled task · Done 13 hours ago · took 2m 54s". `now` is milliseconds. */
export function runDetail(run: HomeBackgroundRun, now: number, locale?: string): string {
  const kind = run.kind === "incident" ? "Incident" : "Scheduled task";
  const nowApple = now / 1000 - APPLE_EPOCH;
  const elapsed = elapsedLabel(run.startedAt, run.finishedAt, nowApple);
  const repeats = repeatsText(run.repeats);
  const tab = runTabTitle(run);
  if (runIsRunning(run)) {
    if (tab) {
      const state = runTabHandoff(run)?.status === "queued" ? "Queued in" : "Running in";
      return `${kind} · ${state} ${tab} for ${elapsed}${repeats}`;
    }
    return `${kind} · Running for ${elapsed}${repeats}`;
  }
  const when = relativeNamed(new Date(appleToUnix(run.finishedAt ?? run.startedAt) * 1000), now, locale);
  if (run.status === "skipped") return `${kind} · Skipped ${when}${repeats}`;
  const place = tab ? ` in ${tab}` : "";
  return `${kind} · ${runStatusText(run)}${place} ${when} · took ${elapsed}${repeats}`;
}

export function queuedRunDetail(item: HomeBackgroundQueuedRun): string {
  const kind = item.kind === "incident" ? "Incident" : "Scheduled task";
  return `${kind} · ${trimmed(item.reason) || "Waiting"}${repeatsText(item.repeats)}`;
}

export type RunIcon = "needsInput" | "tabQueued" | "spinner" | "succeeded" | "failed" | "skipped" | "stopped";

export function runIcon(run: HomeBackgroundRun): RunIcon {
  switch (run.status) {
    case "running":
      if (runNeedsInput(run)) return "needsInput";
      return runTabHandoff(run)?.status === "queued" ? "tabQueued" : "spinner";
    case "succeeded": return "succeeded";
    case "failed": return "failed";
    case "skipped": return "skipped";
    default: return "stopped";
  }
}

/** The VoiceOver announcement after answering a run's request in place. */
export function answerResultText(decision: InputDecision): string {
  switch (decision) {
    case "approve": return "Approved";
    case "deny": return "Denied";
    case "cancel": return "Skipped";
    default: return "Answered";
  }
}

// MARK: "Summary:" sections (CantripHomeRunSummaryText)

export function summaryLines(summary: string): string[] {
  return summary.split(/\r\n|\r|\n/).map((line) => line.replace(/^[ \t]+|[ \t]+$/g, "")).filter((line) => line !== "");
}

/** The "Label: " prefix of a summary line (≤40 characters before ": ", not Markdown syntax). */
export function summaryLabel(line: string): { label: string; rest: string } | null {
  const first = line[0];
  if (!first || "*_#-+>|`[".includes(first)) return null;
  const colon = line.indexOf(": ");
  if (colon < 0 || [...line.slice(0, colon)].length > 40) return null;
  return { label: line.slice(0, colon + 2), rest: line.slice(colon + 2) };
}

/** Lines that each start with a short "Label: ", as a "Summary:" section's do; a full Markdown report isn't. */
export function isLabelledSummary(summary: string): boolean {
  const lines = summaryLines(summary);
  return lines.length >= 2 && lines.length <= 12 && lines.every((line) => summaryLabel(line) !== null);
}

// MARK: Handoff cards (CantripHandoffCard)

type HandoffLike = Pick<HomeBackgroundHandoff, "status" | "latestStatus" | "tabTitle" | "summary" | "prompt"> & { needsInput?: boolean };

export function handoffIsActive(handoff: Pick<HomeBackgroundHandoff, "status">): boolean {
  return handoff.status === "queued" || handoff.status === "running";
}

/** Older Macs only say so in the tab's latest status. */
export function handoffNeedsAnswer(handoff: HandoffLike): boolean {
  if (handoff.status !== "running") return false;
  const latest = trimmed(handoff.latestStatus);
  return handoff.needsInput === true || latest === "Needs your answer" || latest === "Waiting for your input";
}

export function handoffStatusText(handoff: HandoffLike): string {
  if (handoffNeedsAnswer(handoff)) return "Needs your answer";
  switch (handoff.status) {
    case "queued": return "Queued in tab";
    case "running": return "Working in tab";
    case "completed": return "Done in tab";
    case "failed": return "Failed in tab";
    case "cancelled": return "Stopped";
    default: return "Handed off";
  }
}

export function handoffTabTitle(handoff: HandoffLike): string {
  return trimmed(handoff.tabTitle) || "Project tab";
}

export function handoffSummary(handoff: HandoffLike): string {
  return trimmed(handoff.summary) || trimmed(handoff.prompt);
}

// MARK: Queue (CantripQueueView / PromptText)

export const PROMPT_PREVIEW_LIMIT = 1200;
export const PROMPT_PAGE_LIMIT = 4000;

export function promptPreview(text: string): { preview: string; isLong: boolean } {
  const characters = [...text];
  const isLong = characters.length > PROMPT_PREVIEW_LIMIT;
  return { preview: isLong ? characters.slice(0, PROMPT_PREVIEW_LIMIT).join("") : text, isLong };
}

/** The Full prompt reader's pages. */
export function promptPages(text: string): string[] {
  const characters = [...text];
  if (!characters.length) return [""];
  const pages: string[] = [];
  for (let index = 0; index < characters.length; index += PROMPT_PAGE_LIMIT) {
    pages.push(characters.slice(index, index + PROMPT_PAGE_LIMIT).join(""));
  }
  return pages;
}

export function queuePositionLabel(index: number): string {
  return index === 0 ? "Next in queue" : `Queue position ${index + 1}`;
}

export function queuedText(prompt: { text: string; displayText?: string }): string {
  return prompt.displayText ?? prompt.text;
}
