// Pure rules behind Home's Tasks and Artifacts (CantripHomeView.swift, CantripHomeWorkspaceGroups.swift,
// CantripArtifactThumbnails.swift). No DOM or signals, so vitest covers them (tests/home-logic.test.ts).
import type {
  HomeArtifact, HomeBackgroundSnapshot, HomeTask, HomeTaskField, HomeTaskRecord, HomeTaskWorkspace,
} from "../../api/types";
import { APPLE_EPOCH, appleDate, relativeFull } from "../../state/format";

// MARK: Text

/** Swift's `String.capitalized`: each word's first letter upper, the rest lower ("succeeded" → "Succeeded"). */
export function capitalized(value: string): string {
  return value.toLowerCase().replace(/(^|[^\p{L}\p{N}'’])(\p{L})/gu, (_match, before: string, letter: string) => before + letter.toUpperCase());
}

/** The workspace's plural noun ("interview applications"). */
export function pluralLabel(workspace: Pick<HomeTaskWorkspace, "recordLabel" | "recordLabelPlural">): string {
  return workspace.recordLabelPlural ?? `${workspace.recordLabel}s`;
}

export function recordNoun(workspace: Pick<HomeTaskWorkspace, "recordLabel" | "recordLabelPlural">, count: number): string {
  return count === 1 ? workspace.recordLabel : pluralLabel(workspace);
}

/** A task row's second line: "5 briefings" for workspaces, else the schedule's summary. */
export function taskSubtitle(task: HomeTask): string {
  const workspace = task.workspace;
  if (workspace) return `${workspace.records.length} ${recordNoun(workspace, workspace.records.length)}`;
  return task.schedule.summary;
}

export function isScheduled(task: Pick<HomeTask, "hasSchedule">): boolean {
  return task.hasSchedule !== false;
}

// MARK: Task rows

export type TaskStatusKind = "needsInput" | "running" | "failed" | "succeeded" | "paused" | "ready" | "scheduled";

/** The row's leading glyph (CantripHomeTasksView.taskStatus). */
export function taskStatusKind(task: Pick<HomeTask, "state">, waiting: boolean): TaskStatusKind {
  switch (task.state) {
    case "running": return waiting ? "needsInput" : "running";
    case "failed": return "failed";
    case "succeeded": return "succeeded";
    case "paused": return "paused";
    case "ready": return "ready";
    default: return "scheduled";
  }
}

export interface TaskTimeLine {
  icon: "rectangle.stack" | "clock" | "pause";
  text: string;
  /** The latest run's status ("Succeeded"), after a "·". */
  status: string | null;
}

/** "in 52 minutes · Succeeded", "Updated 3 hours ago", or "Paused" (CantripHomeTasksView.taskRow). */
export function taskTimeLine(task: HomeTask, now = Date.now()): TaskTimeLine {
  const run = task.runs[0];
  const status = run ? capitalized(run.status) : null;
  if (!isScheduled(task)) return { icon: "rectangle.stack", text: `Updated ${relativeFull(appleDate(task.updatedAt), now)}`, status };
  if (task.nextRunAt !== undefined && task.nextRunAt !== null && task.enabled) {
    return { icon: "clock", text: relativeFull(appleDate(task.nextRunAt), now), status };
  }
  return { icon: "pause", text: "Paused", status };
}

/** Task ID → hidden session of its live run that waits on the user (CantripHomeTasksView.waitingRuns). */
export function waitingRuns(snapshot: HomeBackgroundSnapshot | null | undefined): Map<string, string> {
  const waiting = new Map<string, string>();
  for (const run of snapshot?.runs ?? []) {
    const needs = run.status === "running" && ((run.inputs ?? []).length > 0 || run.activity === "Needs your input");
    if (needs && run.taskID && run.sessionID) waiting.set(run.taskID.toUpperCase(), run.sessionID);
  }
  return waiting;
}

// MARK: Run summaries (CantripHomeRunSummaryText)

export function summaryLines(summary: string): string[] {
  return summary.split(/\r\n|[\n\r\u2028\u2029\u0085\u000b\u000c]/).map((line) => line.trim()).filter(Boolean);
}

/** Length of a leading short "Label: " (≤40 characters before the colon), or 0. Markdown lines never qualify. */
export function summaryLabelLength(line: string): number {
  const first = line[0];
  if (!first || "*_#-+>|`[".includes(first)) return 0;
  const colon = line.indexOf(": ");
  if (colon < 0 || [...line.slice(0, colon)].length > 40) return 0;
  return colon + 2;
}

export function isLabelledSummary(summary: string): boolean {
  const lines = summaryLines(summary);
  return lines.length >= 2 && lines.length <= 12 && lines.every((line) => summaryLabelLength(line) > 0);
}

// MARK: Reordering

export interface TaskMove { id: string; targetID: string; after: boolean }

/** A list drop (one row from `source` to the gap before `destination`) as a relative move (CantripHomeTaskReorder). */
export function reorderMove(ids: string[], source: number, destination: number): TaskMove | null {
  if (source < 0 || source >= ids.length || destination < 0 || destination > ids.length) return null;
  if (destination === source || destination === source + 1) return null;
  const target = source < destination ? destination - 1 : destination;
  return { id: ids[source], targetID: ids[target], after: source < target };
}

/** The Mac's optimistic preview of a move (CantripRemoteModel.moveHomeTask). */
export function applyMove<T extends { id: string }>(items: readonly T[], id: string, targetID: string, after: boolean): T[] | null {
  const source = items.findIndex((item) => item.id === id);
  const target = items.findIndex((item) => item.id === targetID);
  if (source < 0 || target < 0) return null;
  const preview = items.slice();
  const [moved] = preview.splice(source, 1);
  preview.splice(target - (source < target ? 1 : 0) + (after ? 1 : 0), 0, moved);
  return preview;
}

// MARK: Badges (CantripHomeBadgeTone)

export type BadgeTone = "accent" | "rejected" | "offer" | "applied" | "inProgress";

const IN_PROGRESS = [
  "interview", "screen", "conversation", "scheduled", "assessment", "onsite", "on-site", "final round", "in progress",
  "in-progress", "recruiter", "technical", "hiring manager", "take-home", "phone",
];

export function badgeTone(value: string): BadgeTone {
  const normalized = value.trim().toLowerCase();
  if (normalized.includes("reject") || normalized.includes("declin")) return "rejected";
  if (normalized.includes("offer")) return "offer";
  if (normalized === "applied" || normalized === "application received") return "applied";
  if (IN_PROGRESS.some((word) => normalized.includes(word))) return "inProgress";
  return "accent";
}

// MARK: Workspace groups (CantripHomeWorkspaceGrouping)

export const OTHER_GROUP_ID = "\u0001other";

export interface WorkspaceSection {
  /** Key for the remembered collapse state: the group's title, or OTHER_GROUP_ID. */
  id: string;
  title: string;
  records: HomeTaskRecord[];
  startsCollapsed: boolean;
}

/**
 * Null when the workspace isn't grouped. Explicit groups always show (0 when empty); one-per-option
 * sections and Other only with records. Records keep their saved order. Searching keeps sections with matches.
 */
export function workspaceSections(workspace: HomeTaskWorkspace, records: HomeTaskRecord[], searching = false): WorkspaceSection[] | null {
  const key = workspace.list.groupField;
  if (!key) return null;
  const explicit = workspace.list.groups;
  const groups = explicit ?? (workspace.fields.find((field) => field.key === key)?.options ?? []).map((option) => ({ title: option, values: [option], collapsed: undefined as boolean | undefined }));
  const index = new Map<string, number>();
  groups.forEach((group, position) => {
    for (const value of group.values) if (!index.has(value)) index.set(value, position);
  });
  const buckets: HomeTaskRecord[][] = groups.map(() => []);
  const other: HomeTaskRecord[] = [];
  for (const record of records) {
    const value = record.values[key];
    const position = value === undefined ? undefined : index.get(value);
    if (position === undefined) other.push(record);
    else buckets[position].push(record);
  }
  let sections: WorkspaceSection[] = groups.map((group, position) => ({
    id: group.title, title: group.title, records: buckets[position], startsCollapsed: group.collapsed ?? false,
  }));
  if (!explicit) sections = sections.filter((section) => section.records.length > 0);
  if (other.length) sections.push({ id: OTHER_GROUP_ID, title: "Other", records: other, startsCollapsed: false });
  if (searching) sections = sections.filter((section) => section.records.length > 0);
  return sections;
}

/** Records whose values contain the query, case-insensitively (localizedCaseInsensitiveContains). */
export function filterRecords(records: HomeTaskRecord[], query: string): HomeTaskRecord[] {
  const needle = query.trim().toLocaleLowerCase();
  if (!needle) return records;
  return records.filter((record) => Object.values(record.values).some((value) => String(value).toLocaleLowerCase().includes(needle)));
}

/** Same key as the host's web client, so both remember the same sections on this PC. */
export function groupStateKey(taskID: string): string {
  return `cantrip.workspaceGroups.${taskID}`;
}

type KeyValueStore = Pick<Storage, "getItem" | "setItem" | "removeItem">;

/** Sections the user collapsed (true) or expanded (false). */
export function loadGroupState(taskID: string, storage: KeyValueStore): Record<string, boolean> {
  try {
    const value = JSON.parse(storage.getItem(groupStateKey(taskID)) || "{}") as unknown;
    if (!value || typeof value !== "object" || Array.isArray(value)) return {};
    return Object.fromEntries(Object.entries(value).filter(([, flag]) => typeof flag === "boolean")) as Record<string, boolean>;
  } catch {
    return {};
  }
}

export function saveGroupState(taskID: string, state: Record<string, boolean>, storage: KeyValueStore): void {
  try {
    if (Object.keys(state).length) storage.setItem(groupStateKey(taskID), JSON.stringify(state));
    else storage.removeItem(groupStateKey(taskID));
  } catch { /* storage full or unavailable */ }
}

export function isSectionCollapsed(section: WorkspaceSection, state: Record<string, boolean>): boolean {
  return state[section.id] ?? section.startsCollapsed;
}

// MARK: Record values (CantripHomeTaskValueFormatter)

/** "YYYY-MM-DD" at local midnight; null unless it is a real calendar date. */
export function parseDate(value: string): Date | null {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  if (!match) return null;
  const [year, month, day] = [Number(match[1]), Number(match[2]), Number(match[3])];
  const date = new Date(year, month - 1, day);
  return date.getFullYear() === year && date.getMonth() === month - 1 && date.getDate() === day ? date : null;
}

/** ISO 8601 internet date-time (ISO8601DateFormatter's default: no fractional seconds). */
export function parseDateTime(value: string): Date | null {
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:?\d{2})$/.test(value)) return null;
  const time = Date.parse(value.replace(/([+-]\d{2})(\d{2})$/, "$1:$2"));
  return Number.isNaN(time) ? null : new Date(time);
}

export function dateValue(date: Date): string {
  return `${String(date.getFullYear()).padStart(4, "0")}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}

export function dateTimeValue(date: Date): string {
  return date.toISOString().replace(/\.\d{3}Z$/, "Z");
}

/** An `<input type="datetime-local">` value in local time, or "". */
export function toLocalInput(value: string | undefined): string {
  const date = value ? parseDateTime(value) : null;
  if (!date) return "";
  const pad = (part: number) => String(part).padStart(2, "0");
  return `${dateValue(date)}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

export function fromLocalInput(value: string): string | null {
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/.exec(value);
  if (!match) return null;
  const [year, month, day, hour, minute] = match.slice(1).map(Number);
  const date = new Date(year, month - 1, day, hour, minute);
  return Number.isNaN(date.getTime()) ? null : dateTimeValue(date);
}

/** "Oct 3, 2026" (abbreviated date). */
export function formatDay(date: Date, locale?: string): string {
  return date.toLocaleDateString(locale, { year: "numeric", month: "short", day: "numeric" });
}

/** "Oct 3, 2026, 10:05 PM" (abbreviated date, shortened time). */
export function formatDayTime(date: Date, locale?: string): string {
  return date.toLocaleString(locale, { dateStyle: "medium", timeStyle: "short" });
}

export function displayValue(value: string, field: Pick<HomeTaskField, "kind">, locale?: string): string {
  switch (field.kind) {
    case "boolean": return value === "true" ? "Yes" : "No";
    case "date": {
      const date = parseDate(value);
      return date ? formatDay(date, locale) : value;
    }
    case "dateTime": {
      const date = parseDateTime(value);
      return date ? formatDayTime(date, locale) : value;
    }
    default: return value;
  }
}

export function fieldFor(workspace: HomeTaskWorkspace, key: string): HomeTaskField | undefined {
  return workspace.fields.find((field) => field.key === key);
}

export function recordTitle(workspace: HomeTaskWorkspace, record: HomeTaskRecord): string {
  return record.values[workspace.list.titleField] ?? workspace.recordLabel;
}

/** "Role: Staff Engineer · Location: Remote" */
export function recordSubtitle(workspace: HomeTaskWorkspace, record: HomeTaskRecord, locale?: string): string {
  return workspace.list.subtitleFields.flatMap((key) => {
    const value = record.values[key];
    const field = fieldFor(workspace, key);
    return value !== undefined && field ? [`${field.label}: ${displayValue(value, field, locale)}`] : [];
  }).join(" · ");
}

export function recordBadge(workspace: HomeTaskWorkspace, record: HomeTaskRecord): string | null {
  const key = workspace.list.badgeField;
  const value = key ? record.values[key] : undefined;
  return value ? value : null;
}

export function recordDate(workspace: HomeTaskWorkspace, record: HomeTaskRecord, locale?: string): string | null {
  const key = workspace.list.dateField;
  const value = key ? record.values[key] : undefined;
  const field = key ? fieldFor(workspace, key) : undefined;
  return value !== undefined && field ? displayValue(value, field, locale) : null;
}

export function detailSections(workspace: HomeTaskWorkspace): { title?: string; fields: string[] }[] {
  return workspace.detailSections.length ? workspace.detailSections : [{ fields: workspace.fields.map((field) => field.key) }];
}

/** The editor's starting values: the record's, then "false" for switches and today for required dates. */
export function initialRecordValues(workspace: HomeTaskWorkspace, record: HomeTaskRecord | null, now = new Date()): Record<string, string> {
  const values: Record<string, string> = { ...(record?.values ?? {}) };
  for (const field of workspace.fields) {
    if (values[field.key] !== undefined) continue;
    if (field.kind === "boolean") values[field.key] = "false";
    else if (field.kind === "date" && field.required) values[field.key] = dateValue(now);
    else if (field.kind === "dateTime" && field.required) values[field.key] = dateTimeValue(now);
  }
  return values;
}

export function canSaveRecord(workspace: HomeTaskWorkspace, values: Record<string, string>): boolean {
  return workspace.fields.every((field) => !field.required || (values[field.key] ?? "").trim() !== "");
}

// MARK: Artifacts (CantripArtifactThumbnailStore, CantripArtifactThumbnailView, CantripArtifactCardLabel)

/** Changes whenever the artifact's file is replaced (size or modification date). */
export function artifactKey(artifact: Pick<HomeArtifact, "id" | "size" | "createdAt">): string {
  return `${artifact.id.toUpperCase()}-${artifact.size}-${Math.round((artifact.createdAt + APPLE_EPOCH) * 1000)}`;
}

export function isImageArtifact(artifact: Pick<HomeArtifact, "kind" | "mimeType">): boolean {
  return artifact.kind === "image" || artifact.mimeType.startsWith("image/");
}

export function isVideoArtifact(artifact: Pick<HomeArtifact, "kind" | "mimeType">): boolean {
  return artifact.kind === "video" || artifact.mimeType.startsWith("video/");
}

export function supportsThumbnail(artifact: Pick<HomeArtifact, "kind" | "mimeType">): boolean {
  return isImageArtifact(artifact) || isVideoArtifact(artifact);
}

export type ArtifactGlyph = "photo" | "play.rectangle.fill" | "waveform" | "doc.richtext.fill" | "doc.text.fill";

export function artifactGlyph(artifact: Pick<HomeArtifact, "kind" | "mimeType">): ArtifactGlyph {
  switch (artifact.kind) {
    case "image": return "photo";
    case "video": return "play.rectangle.fill";
    case "audio": return "waveform";
    default: return artifact.mimeType === "application/pdf" ? "doc.richtext.fill" : "doc.text.fill";
  }
}

/** "0:07", "12:30" or "1:02:03", like Photos. */
export function durationLabel(seconds: number): string {
  const total = Math.max(1, Math.round(seconds));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const rest = total % 60;
  return hours > 0
    ? `${hours}:${String(minutes).padStart(2, "0")}:${String(rest).padStart(2, "0")}`
    : `${minutes}:${String(rest).padStart(2, "0")}`;
}

/** "12 seconds", "1 minute, 5 seconds" (Duration units, wide). */
export function spokenDuration(seconds: number): string {
  const total = Math.max(1, Math.round(seconds));
  const parts: [number, string][] = [[Math.floor(total / 3600), "hour"], [Math.floor((total % 3600) / 60), "minute"], [total % 60, "second"]];
  return parts.filter(([count]) => count > 0).map(([count, unit]) => `${count} ${unit}${count === 1 ? "" : "s"}`).join(", ");
}

/** ByteCountFormatter's `.file` style: 1000-based, "Zero KB", whole KB, one decimal MB, two GB. */
export function fileSize(bytes: number): string {
  if (!(bytes >= 0)) return "";
  if (bytes === 0) return "Zero KB";
  if (bytes < 1000) return `${bytes} ${bytes === 1 ? "byte" : "bytes"}`;
  const units: [string, number][] = [["KB", 0], ["MB", 1], ["GB", 2], ["TB", 2]];
  let value = bytes / 1000;
  let unit = 0;
  while (unit < units.length - 1 && Number(value.toFixed(units[unit][1])) >= 1000) {
    value /= 1000;
    unit++;
  }
  const digits = units[unit][1];
  const text = Number(value.toFixed(digits)).toLocaleString("en-US", { maximumFractionDigits: digits });
  return `${text} ${units[unit][0]}`;
}

/** "Set walk-in, Video, 12 seconds, 2 KB" */
export function artifactAccessibilityText(artifact: Pick<HomeArtifact, "title" | "kind" | "size">, duration?: number | null): string {
  const parts = [artifact.title, capitalized(artifact.kind)];
  if (duration !== undefined && duration !== null) parts.push(spokenDuration(duration));
  parts.push(fileSize(artifact.size));
  return parts.join(", ");
}

/** A safe file name: the title, with the file's extension unless the title already ends with it. */
export function artifactFileName(artifact: Pick<HomeArtifact, "title" | "relativePath">): string {
  const last = artifact.relativePath.split("/").pop() ?? "";
  const dot = last.lastIndexOf(".");
  const ext = dot > 0 ? last.slice(dot + 1) : "";
  const base = artifact.title.replace(/[^A-Za-z0-9._ -]/g, "_") || "Artifact";
  return !ext || base.toLowerCase().endsWith(`.${ext.toLowerCase()}`) ? base : `${base}.${ext}`;
}
