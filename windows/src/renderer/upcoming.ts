// Tasks → Upcoming in the read-only Home window (docs/cantrip-home.md "Upcoming"): reading the Mac's list leniently,
// its groups (Next up cut to 6 until Show all) and each row's words, the same rules as Cantrip's other clients. No
// buttons here: Cancel, Stop, Pause and Resume stay on the phone and the Mac.

/** One thing set to run later, as the Mac sends it. */
export interface UpcomingItem {
  id: string;
  kind: string;
  title: string;
  detail?: string;
  /** Unix seconds (since 1970). */
  nextRunAt?: number;
  /** "Once", "Daily at 3:00 AM", "Every 15 minutes", "Waiting, until Fri Nov 20, 9:50 AM", "Running for 8 h". */
  schedule: string;
  /** Who set it up: a tab's title, "Cantrip Home", "This Mac". */
  owner: string;
  state: string;
  group: string;
}

export type UpcomingGroup = "next" | "waiting" | "repeating" | "paused";

export const UPCOMING_GROUPS: readonly { id: UpcomingGroup; title: string }[] = [
  { id: "next", title: "Next up" },
  { id: "waiting", title: "Waiting" },
  { id: "repeating", title: "Repeating" },
  { id: "paused", title: "Paused" },
];
/** Next up shows this many until Show all. */
export const UPCOMING_NEXT_LIMIT = 6;
/** The line under the heading: this window can't change anything on the Mac. */
export const UPCOMING_READ_ONLY_NOTE = "Cancel or pause from Cantrip on your phone or Mac.";

const isObject = (value: unknown): value is Record<string, unknown> => value !== null && typeof value === "object" && !Array.isArray(value);
const text = (value: unknown): string | undefined => (typeof value === "string" && value.trim() ? value : undefined);

function upcomingItem(value: unknown): UpcomingItem | null {
  if (!isObject(value) || !text(value.id)) return null;
  return {
    id: value.id as string,
    kind: text(value.kind) ?? "task",
    title: text(value.title) ?? "Untitled",
    detail: text(value.detail),
    nextRunAt: typeof value.nextRunAt === "number" && Number.isFinite(value.nextRunAt) ? value.nextRunAt : undefined,
    schedule: text(value.schedule) ?? "",
    owner: text(value.owner) ?? "",
    state: text(value.state) ?? "scheduled",
    group: text(value.group) ?? "next",
  };
}

/** The list answer: its items and revision, or `unchanged`; null for anything else. */
export function parseUpcoming(data: unknown): { unchanged: true; revision?: string } | { unchanged: false; items: UpcomingItem[]; revision?: string } | null {
  if (!isObject(data)) return null;
  const revision = text(data.revision);
  if (data.unchanged === true) return { unchanged: true, revision };
  if (!Array.isArray(data.items)) return null;
  return { unchanged: false, items: data.items.map(upcomingItem).filter((item): item is UpcomingItem => item !== null), revision };
}

export interface UpcomingSection {
  id: UpcomingGroup;
  title: string;
  /** The rows to draw (Next up cut to `UPCOMING_NEXT_LIMIT` until Show all). */
  items: UpcomingItem[];
  total: number;
}

/** The groups with items, in order, keeping the Mac's order inside each (a group it doesn't name counts as Next up). */
export function upcomingSections(items: readonly UpcomingItem[], showAll: boolean): UpcomingSection[] {
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
 * `nextRunAt` in this PC's locale and time zone, relative to today: "Today 10:35 PM", "Tomorrow 3:00 AM",
 * "Yesterday 11:00 PM", the weekday within a week ("Friday 9:50 AM"), else the date ("Nov 25, 9:50 AM", with the year
 * when it isn't this one). Empty without a time.
 */
export function upcomingWhen(seconds: number | undefined, now: Date = new Date(), locale?: string, timeZone?: string): string {
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
export function upcomingMeta(item: UpcomingItem, now: Date = new Date(), locale?: string, timeZone?: string): string {
  const when = upcomingWhen(item.nextRunAt, now, locale, timeZone);
  const parts = [when || item.schedule, when ? item.schedule : "", item.owner];
  return parts.filter((part, index) => part && parts.indexOf(part) === index).join(" · ");
}
