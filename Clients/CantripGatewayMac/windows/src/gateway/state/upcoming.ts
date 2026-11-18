// Cantrip Home's Upcoming list (Cantrip's docs/cantrip-home.md "Upcoming"): the API's paths, reading what the Mac
// sends leniently, the groups the Tasks screen shows and each row's words. No DOM or signals, so vitest covers it all.
import type { HomeUpcomingItem } from "../api/types";

const UPCOMING = "/api/v1/home/upcoming";

/** Next up shows this many until Show all. */
export const UPCOMING_NEXT_LIMIT = 6;

export type UpcomingGroup = "next" | "waiting" | "repeating" | "paused";

/** The groups in the order they show, with their headings. */
export const UPCOMING_GROUPS: readonly { id: UpcomingGroup; title: string }[] = [
  { id: "next", title: "Next up" },
  { id: "waiting", title: "Waiting" },
  { id: "repeating", title: "Repeating" },
  { id: "paused", title: "Paused" },
];

function isObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function text(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value : undefined;
}

/** `GET /api/v1/home/upcoming[?revision=]`. */
export function upcomingPath(revision?: string | null): string {
  return revision ? `${UPCOMING}?revision=${encodeURIComponent(revision)}` : UPCOMING;
}

/** `POST /api/v1/home/upcoming/cancel` or `…/resume`, with the item's id as the body. */
export function upcomingActionRequest(kind: "cancel" | "resume", id: string): { path: string; body: { id: string } } {
  return { path: `${UPCOMING}/${kind}`, body: { id } };
}

/** An item the list can show, or null for something that isn't one. */
export function upcomingItem(value: unknown): HomeUpcomingItem | null {
  if (!isObject(value) || !text(value.id)) return null;
  const nextRunAt = typeof value.nextRunAt === "number" && Number.isFinite(value.nextRunAt) ? value.nextRunAt : undefined;
  return {
    id: value.id as string,
    kind: text(value.kind) ?? "task",
    title: text(value.title) ?? "Untitled",
    detail: text(value.detail),
    nextRunAt,
    schedule: text(value.schedule) ?? "",
    owner: text(value.owner) ?? "",
    ownerTabID: text(value.ownerTabID),
    state: text(value.state) ?? "scheduled",
    group: text(value.group) ?? "next",
    cancelLabel: text(value.cancelLabel),
    confirm: text(value.confirm),
    canResume: value.canResume === true,
  };
}

/** The list answer (or an action's): the items and revision, `unchanged`, and the Mac's `message` when it sent one. */
export function parseUpcoming(data: unknown):
  | { unchanged: true; revision: string | null }
  | { unchanged: false; items: HomeUpcomingItem[]; revision: string | null; message: string | null } {
  if (!isObject(data)) throw new Error("The Mac sent no Upcoming list.");
  const revision = text(data.revision) ?? null;
  if (data.unchanged === true) return { unchanged: true, revision };
  if (!Array.isArray(data.items)) throw new Error("The Mac sent no Upcoming list.");
  const items = data.items.map(upcomingItem).filter((item): item is HomeUpcomingItem => item !== null);
  return { unchanged: false, items, revision, message: text(data.message) ?? null };
}

export interface UpcomingSection {
  id: UpcomingGroup;
  title: string;
  /** The rows to draw (Next up cut to `UPCOMING_NEXT_LIMIT` until Show all). */
  items: HomeUpcomingItem[];
  /** Everything in the group. */
  total: number;
}

/** The groups with items, in order, keeping the Mac's order inside each (a group it doesn't name counts as Next up). */
export function upcomingSections(items: readonly HomeUpcomingItem[], showAll: boolean): UpcomingSection[] {
  const known = new Set<string>(UPCOMING_GROUPS.map((group) => group.id));
  return UPCOMING_GROUPS.map(({ id, title }) => {
    const all = items.filter((item) => (known.has(item.group) ? item.group : "next") === id);
    return { id, title, total: all.length, items: id === "next" && !showAll ? all.slice(0, UPCOMING_NEXT_LIMIT) : all };
  }).filter((section) => section.total > 0);
}

function dayNumber(date: Date, timeZone: string | undefined): number {
  const parts = new Intl.DateTimeFormat("en-US", { timeZone, year: "numeric", month: "numeric", day: "numeric" }).formatToParts(date);
  const part = (type: Intl.DateTimeFormatPartTypes) => Number(parts.find((item) => item.type === type)?.value);
  return Date.UTC(part("year"), part("month") - 1, part("day")) / 86_400_000;
}

/**
 * `nextRunAt` (Unix seconds) in the viewer's locale and time zone, relative to today: "Today 10:35 PM",
 * "Tomorrow 3:00 AM", "Yesterday 11:00 PM", the weekday within a week ("Friday 9:50 AM"), else the date ("Nov 25,
 * 9:50 AM", with the year when it isn't this one). Empty without a time.
 */
export function upcomingWhen(seconds: number | null | undefined, now: Date = new Date(), locale?: string, timeZone?: string): string {
  if (typeof seconds !== "number" || !Number.isFinite(seconds)) return "";
  const date = new Date(seconds * 1000);
  const days = Math.round(dayNumber(date, timeZone) - dayNumber(now, timeZone));
  const time = date.toLocaleTimeString(locale, { timeZone, hour: "numeric", minute: "2-digit" });
  if (days === 0) return `Today ${time}`;
  if (days === 1) return `Tomorrow ${time}`;
  if (days === -1) return `Yesterday ${time}`;
  if (days > 1 && days < 7) return `${date.toLocaleDateString(locale, { timeZone, weekday: "long" })} ${time}`;
  const year = (value: Date) => new Intl.DateTimeFormat("en-US", { timeZone, year: "numeric" }).format(value);
  // Date and time joined here: engines differ in how toLocaleString joins them ("Nov 25, 9:50 AM", "Nov 25 at 9:50 AM").
  return `${date.toLocaleDateString(locale, { timeZone, month: "short", day: "numeric", ...(year(date) === year(now) ? {} : { year: "numeric" }) })}, ${time}`;
}

/** A row's second line: when (or the schedule when there's no time), then the schedule and who set it up, each once. */
export function upcomingMeta(item: HomeUpcomingItem, now: Date = new Date(), locale?: string, timeZone?: string): string {
  const when = upcomingWhen(item.nextRunAt, now, locale, timeZone);
  const parts = [when || item.schedule, when ? item.schedule : "", item.owner];
  return parts.filter((part, index) => part && parts.indexOf(part) === index).join(" · ");
}

/** The row's button: Resume when the Mac can resume it (no question), else its cancelLabel (asks first), else none. */
export function upcomingAction(item: HomeUpcomingItem): { kind: "cancel" | "resume"; label: string } | null {
  if (item.canResume) return { kind: "resume", label: "Resume" };
  return item.cancelLabel ? { kind: "cancel", label: item.cancelLabel } : null;
}

/** The question before Cancel, Stop or Pause: the Mac's own, else one naming the item. */
export function upcomingQuestion(item: HomeUpcomingItem, label: string): string {
  return item.confirm ?? `${label} “${item.title}”?`;
}
