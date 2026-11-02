// Cantrip Home, read from the paired Mac: the IPC contract between the Home window and the main
// process, the parts of the Mac's Home API this client draws (`docs/cantrip-home.md`), and pure
// helpers the window and tests share.
import type { CardDocument } from "./cards";

/** What the Home window may ask the main process to read; it builds and checks each path. */
export type HomeRead =
  | { kind: "home" }
  | { kind: "background" }
  /** Home's background log: every run's full reply. The ID comes from the last Background read. */
  | { kind: "log" }
  | { kind: "tasks"; revision?: string }
  | { kind: "recordCards"; taskID: string; recordID: string };

export type HomeReadResult =
  | { ok: true; data: unknown }
  | { ok: false; error: string; status?: number };

export interface HomeStatus {
  paired: boolean;
  /** The Mac's name from the pairing link. */
  server: string;
  /** The route in use, e.g. "Direct, encrypted (192.168.0.20:8766)". */
  route: string;
}

export type HomePairResult = { ok: true; status: HomeStatus; notice?: string } | { ok: false; error: string };

export interface CantripHomeApi {
  status(): Promise<HomeStatus>;
  pair(link: string): Promise<HomePairResult>;
  unpair(): Promise<HomeStatus>;
  read(request: HomeRead): Promise<HomeReadResult>;
  openExternal(url: string): Promise<boolean>;
}

// MARK: - The Mac's Home API (read-only subset)

export interface HomeMessage {
  id: string;
  /** "user", "assistant", "error", "handoff" (a Home result card) or "freshStart" (a divider). */
  role: string;
  text: string;
  /** Shown instead of `text` when present. */
  displayText?: string;
  /** role "handoff": a tab's result for Home (plain text, never Markdown). */
  handoffResult?: { tabTitle: string; summary: string; state: string; detail: string };
  /** Every card under the reply, resolved on the Mac. */
  cards?: CardDocument[];
}

export interface HomeSession {
  id: string;
  title?: string;
  messages: HomeMessage[];
  hasOlderMessages?: boolean;
}

export interface HomeBackgroundRun {
  id: string;
  kind: string;
  label: string;
  taskID?: string;
  /** Apple reference seconds. */
  startedAt: number;
  finishedAt?: number;
  /** "running", "succeeded", "failed", "cancelled", … */
  status: string;
  summary: string;
  activity?: string;
  model?: string;
  cards?: CardDocument[];
}

export interface HomeBackgroundQueued {
  id: string;
  label: string;
  reason?: string;
  dueAt?: number;
}

export interface HomeBackgroundSnapshot {
  sessionID: string;
  runs: HomeBackgroundRun[];
  queued: HomeBackgroundQueued[];
  maxParallel?: number;
  runningCount?: number;
}

export interface HomeTaskRun {
  id: string;
  startedAt: number;
  finishedAt: number;
  status: string;
  summary: string;
  model?: string;
  cards?: CardDocument[];
}

export interface HomeTaskField {
  key: string;
  label: string;
  kind: string;
}

export interface HomeTaskRecord {
  id: string;
  values: Record<string, string>;
}

export interface HomeTaskWorkspace {
  recordLabel: string;
  recordLabelPlural?: string;
  fields: HomeTaskField[];
  list: { titleField: string; subtitleFields: string[]; dateField?: string };
  detailSections: { title?: string; fields: string[] }[];
  records: HomeTaskRecord[];
  cards?: { kind: string }[];
}

export interface HomeTask {
  id: string;
  title: string;
  schedule: { summary: string };
  hasSchedule?: boolean;
  enabled: boolean;
  state: string;
  nextRunAt?: number;
  runs: HomeTaskRun[];
  workspace?: HomeTaskWorkspace;
}

export interface HomeTasksSnapshot {
  tasks: HomeTask[];
  revision: string;
  error?: string;
  workspaceCards?: Record<string, CardDocument[]>;
  supportsRecordCards?: boolean;
}

// MARK: - Helpers

export const UUID_PATTERN = /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/;

/** Seconds between 1970-01-01 and 2001-01-01, the epoch of the Mac's encoded dates. */
const APPLE_EPOCH = 978_307_200;

export function appleDate(seconds: unknown): Date | null {
  return typeof seconds === "number" && Number.isFinite(seconds) ? new Date((seconds + APPLE_EPOCH) * 1000) : null;
}

const STATUS_LABELS: Record<string, string> = {
  running: "Running",
  succeeded: "Succeeded",
  failed: "Failed",
  cancelled: "Cancelled",
  interrupted: "Interrupted",
  skipped: "Skipped",
  ready: "Ready",
  scheduled: "Scheduled",
  paused: "Paused",
};

export function statusLabel(status: string): string {
  return STATUS_LABELS[status] ?? (status ? status[0].toUpperCase() + status.slice(1) : "Unknown");
}

export type StatusTone = "positive" | "negative" | "accent" | "neutral";

export function statusTone(status: string): StatusTone {
  if (status === "succeeded") return "positive";
  if (status === "failed") return "negative";
  if (status === "running") return "accent";
  return "neutral";
}

/** Drops anything that isn't a card document, so a malformed card can't break a list. */
export function cardsOf(value: unknown): CardDocument[] {
  if (!Array.isArray(value)) return [];
  return value.filter((card): card is CardDocument =>
    Boolean(card) && typeof card === "object" && Array.isArray((card as CardDocument).blocks));
}

/** Whether a workspace's cards include ones the Mac builds per record (forecast, map). */
export function hasRecordCards(workspace: Pick<HomeTaskWorkspace, "cards"> | undefined): boolean {
  return Boolean(workspace?.cards?.some((card) => card.kind === "weather" || card.kind === "map"));
}

/** A record's row title: its list title field, else its first non-empty value. */
export function recordTitle(workspace: HomeTaskWorkspace, record: HomeTaskRecord): string {
  const title = record.values[workspace.list.titleField]?.trim();
  if (title) return title;
  return Object.values(record.values).find((value) => value.trim())?.trim() ?? workspace.recordLabel;
}

/** Labeled values for a record's detail, in the workspace's detail sections (or field order). */
export function recordDetails(workspace: HomeTaskWorkspace, record: HomeTaskRecord): { title?: string; rows: { label: string; value: string }[] }[] {
  const labels = new Map(workspace.fields.map((field) => [field.key, field.label]));
  const sections = workspace.detailSections.length
    ? workspace.detailSections
    : [{ fields: workspace.fields.map((field) => field.key) }];
  return sections
    .map((section) => ({
      title: section.title,
      rows: section.fields
        .filter((key) => record.values[key]?.trim())
        .map((key) => ({ label: labels.get(key) ?? key, value: record.values[key].trim() })),
    }))
    .filter((section) => section.rows.length);
}
