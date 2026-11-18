// Tasks → Views as a grid of thumbnails (the same rules on every client): the grid's column count, the blocks a
// thumbnail previews, the Views, Upcoming and Tasks sections' collapsed state, and when a thumbnail's view is fetched again.
import type { Block, CardDocument } from "../shared/cards";
import type { HomeViewSummary, ShownView } from "../shared/views";
import { viewSubtitle } from "../shared/views";

export const GRID_GAP = 12;
/** Thumbnail fetches in flight at once. */
export const MAX_THUMB_REQUESTS = 2;
/** After a failed thumbnail fetch, how long before trying again. */
export const THUMB_RETRY_MS = 30_000;

/** Columns for a grid `width` wide: at least 160 wide under 600, else 240, 12 apart, 1 to 6. */
export function gridColumns(width: number): number {
  if (!Number.isFinite(width)) return 1;
  const min = width < 600 ? 160 : 240;
  return Math.min(6, Math.max(1, Math.floor((width + GRID_GAP) / (min + GRID_GAP))));
}

export type HomeSection = "views" | "upcoming" | "tasks";
export const SECTION_KEYS: Readonly<Record<HomeSection, string>> = {
  views: "cantrip.home.views.collapsed",
  upcoming: "cantrip.home.upcoming.collapsed",
  tasks: "cantrip.home.tasks.collapsed",
};
type FlagStore = Pick<Storage, "getItem" | "setItem">;

/** Whether this window keeps `section` collapsed ("1"; anything else is expanded). */
export function sectionCollapsed(store: FlagStore | undefined, section: HomeSection): boolean {
  try {
    return store?.getItem(SECTION_KEYS[section]) === "1";
  } catch {
    return false;
  }
}

export function setSectionCollapsed(store: FlagStore | undefined, section: HomeSection, collapsed: boolean): void {
  try {
    store?.setItem(SECTION_KEYS[section], collapsed ? "1" : "0");
  } catch {
    // Storage can be unavailable; the section still toggles for this render.
  }
}

/** The heading's accessible name: "Views, 6 views", "Tasks, 1 task". */
export function sectionLabel(title: string, count: number, noun: string): string {
  return `${title}, ${count} ${count === 1 ? noun : `${noun}s`}`;
}

/** The count after a collapsed heading's title ("· 6"); nothing while it's expanded, unless it always shows (Upcoming). */
export function sectionCount(count: number, collapsed: boolean, always = false): string {
  return collapsed || always ? `· ${count}` : "";
}

const isBlock = (value: unknown): value is Block => Boolean(value) && typeof value === "object" && typeof (value as Block).type === "string";
const ROWS: Record<string, "tableRows" | "items" | "rows"> = { table: "tableRows", list: "items", keyValue: "rows" };

/**
 * What a thumbnail previews from a view's resolved card, which is flat: a `tabs` block owns the next `count` blocks
 * for each tab in turn (only the first tab's count), and a `section` is a heading before its blocks. Up to 2 stats and
 * the first chart in document order; else the first table, list or key-value block, trimmed to 3 rows.
 */
export function previewBlocks(card: Pick<CardDocument, "blocks"> | null | undefined): Block[] {
  const blocks: unknown[] = Array.isArray(card?.blocks) ? card.blocks : [];
  const visible: Block[] = [];
  for (let index = 0; index < blocks.length; index++) {
    const block = blocks[index];
    if (!isBlock(block)) continue;
    if (block.type === "tabs") {
      const counts = (Array.isArray(block.tabs) ? block.tabs : []).map((tab) =>
        Math.max(0, Math.floor(Number((tab as { count?: unknown } | null)?.count) || 0)));
      for (const child of blocks.slice(index + 1, index + 1 + (counts[0] ?? 0))) if (isBlock(child) && child.type !== "tabs") visible.push(child);
      index += counts.reduce((sum, count) => sum + count, 0);
      continue;
    }
    visible.push(block);
  }
  const stats = visible.filter((block) => block.type === "stat").slice(0, 2);
  const chart = visible.find((block) => block.type === "chart");
  if (stats.length || chart) return visible.filter((block) => stats.includes(block) || block === chart);
  const other = visible.find((block) => Object.prototype.hasOwnProperty.call(ROWS, block.type));
  if (!other) return [];
  const key = ROWS[other.type];
  const rows = other[key];
  return [{ ...other, [key]: Array.isArray(rows) ? rows.slice(0, 3) : [] }];
}

/** A thumbnail's view as last fetched (`shown` stays from an earlier fetch when the latest one failed). */
export interface ThumbEntry {
  shown: ShownView | null;
  fetchedAt: number;
  failed: boolean;
}

const stamp = (value: unknown): string => (value === undefined || value === null ? "" : String(value));

/** Fetch again when there's nothing cached, the list's summary changed since, or its `refreshAfter` passed. */
export function thumbDue(entry: ThumbEntry | undefined, summary: Pick<HomeViewSummary, "updatedAt" | "refreshedAt">, now: number): boolean {
  if (!entry) return true;
  if (entry.failed) return now - entry.fetchedAt >= THUMB_RETRY_MS;
  const seen = entry.shown?.view;
  if (!seen) return true;
  if (stamp(seen.updatedAt) !== stamp(summary.updatedAt) || stamp(seen.refreshedAt) !== stamp(summary.refreshedAt)) return true;
  return now - entry.fetchedAt >= entry.shown!.refreshMs;
}

/** The views to fetch now, in list order, keeping at most `MAX_THUMB_REQUESTS` in flight. */
export function thumbsToFetch(views: readonly HomeViewSummary[], cache: ReadonlyMap<string, ThumbEntry>, inFlight: ReadonlySet<string>, now: number): string[] {
  const free = MAX_THUMB_REQUESTS - inFlight.size;
  if (free <= 0) return [];
  return views.filter((view) => !inFlight.has(view.id) && thumbDue(cache.get(view.id), view, now)).slice(0, free).map((view) => view.id);
}

/** One label for the whole thumbnail: name, Pinned, Private, its second line, Refreshing, problems. */
export function thumbLabel(view: HomeViewSummary, now = new Date()): string {
  const problems = Array.isArray(view.problems) ? view.problems.length : 0;
  return [
    view.name,
    view.pinned ? "Pinned" : "",
    view.private ? "Private" : "",
    viewSubtitle(view, now),
    view.refreshing ? "Refreshing" : "",
    problems ? `${problems} ${problems === 1 ? "problem" : "problems"}` : "",
  ].filter(Boolean).join(", ");
}

/** The small line under a thumbnail's preview: "Refreshing…", else the first problem. */
export function thumbNote(view: HomeViewSummary): { text: string; warning: boolean } | null {
  if (view.refreshing) return { text: "Refreshing…", warning: false };
  const problem = Array.isArray(view.problems) ? view.problems.find((text) => typeof text === "string" && text.trim()) : undefined;
  return problem ? { text: problem, warning: true } : null;
}
