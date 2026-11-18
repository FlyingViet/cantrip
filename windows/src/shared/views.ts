// Cantrip Home's Views (docs/views.md) in the read-only Home window: what the Mac sends, read leniently, and the
// action buttons this window may run. Shared by the main process (which checks every write) and the window.
import type { CardDocument } from "./cards";

/** A view's summary: the list's rows and the `view` of a view answer. Times are ISO 8601 (or Apple reference seconds). */
export interface HomeViewSummary {
  id: string;
  name: string;
  subtitle?: string | null;
  icon?: string | null;
  pinned: boolean;
  /** Reads a private server: shown with a lock. */
  private: boolean;
  sources?: string[];
  createdAt?: string | number;
  updatedAt?: string | number;
  refreshedAt?: string | number | null;
  refreshing?: boolean;
  problems?: string[];
}

export interface ShownView {
  view: HomeViewSummary;
  card: CardDocument;
  /** When to fetch it again while it stays open. */
  refreshMs: number;
}

/** This window is read-only: of a view's buttons it runs only Refresh and links, and hides the rest. */
export const HOME_WINDOW_ACTION_KINDS: ReadonlySet<string> = new Set(["refresh", "open"]);
/** View and action IDs the window may name (UUIDs and the Mac's short IDs). */
export const VIEW_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;

export const VIEW_REFRESH_MS = 60_000;
export const VIEW_MIN_REFRESH_MS = 10_000;
export const VIEW_MAX_REFRESH_MS = 3_600_000;

/** Seconds between 1970-01-01 and 2001-01-01, the epoch of the Mac's encoded dates. */
const APPLE_EPOCH = 978_307_200;

function isObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function text(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value : undefined;
}

export function viewSummary(value: unknown): HomeViewSummary | null {
  if (!isObject(value) || !text(value.id) || !text(value.name)) return null;
  return {
    ...(value as unknown as HomeViewSummary),
    id: value.id as string,
    name: value.name as string,
    subtitle: text(value.subtitle) ?? null,
    icon: text(value.icon) ?? null,
    pinned: value.pinned === true,
    private: value.private === true,
  };
}

/** Pinned first; otherwise the Mac's order (newest first). */
export function orderedViews(views: HomeViewSummary[]): HomeViewSummary[] {
  return views.map((view, index) => ({ view, index }))
    .sort((a, b) => Number(b.view.pinned) - Number(a.view.pinned) || a.index - b.index)
    .map(({ view }) => view);
}

/** The views list answer, or null for one that isn't (`unchanged` keeps what's shown). */
export function parseViews(data: unknown): { unchanged: true; revision?: string } | { unchanged: false; views: HomeViewSummary[]; revision?: string } | null {
  if (!isObject(data)) return null;
  const revision = text(data.revision);
  if (data.unchanged === true) return { unchanged: true, revision };
  if (!Array.isArray(data.views)) return null;
  const views = data.views.map(viewSummary).filter((view): view is HomeViewSummary => view !== null);
  return { unchanged: false, views: orderedViews(views), revision };
}

export function viewRefreshDelay(refreshAfter: unknown): number {
  if (typeof refreshAfter !== "number" || !Number.isFinite(refreshAfter) || refreshAfter <= 0) return VIEW_REFRESH_MS;
  return Math.min(VIEW_MAX_REFRESH_MS, Math.max(VIEW_MIN_REFRESH_MS, Math.round(refreshAfter * 1000)));
}

/** A view answer (`GET …/views/<id>`, `POST …/refresh`, a `refreshed` action), or null. */
export function parseView(data: unknown): ShownView | null {
  if (!isObject(data)) return null;
  const view = viewSummary(data.view);
  const card = data.card;
  if (!view || !isObject(card) || !Array.isArray(card.blocks)) return null;
  return { view, card: card as unknown as CardDocument, refreshMs: viewRefreshDelay(data.refreshAfter) };
}

/** The IDs of a view card's buttons of `kinds` (what the window may post back). */
export function viewActionIDs(card: unknown, kinds: ReadonlySet<string> = HOME_WINDOW_ACTION_KINDS): string[] {
  if (!isObject(card) || !Array.isArray(card.blocks)) return [];
  return card.blocks.flatMap((block) => {
    if (!isObject(block) || block.type !== "actions" || !Array.isArray(block.buttons)) return [];
    return block.buttons.flatMap((button) =>
      isObject(button) && typeof button.id === "string" && VIEW_ID_PATTERN.test(button.id) && typeof button.kind === "string" && kinds.has(button.kind)
        ? [button.id] : []);
  });
}

export function viewDate(value: unknown): Date | null {
  if (typeof value === "number" && Number.isFinite(value)) return new Date((value + APPLE_EPOCH) * 1000);
  if (typeof value !== "string" || !value) return null;
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? null : date;
}

/** The row's second line: the subtitle, else "Updated 3:39 PM" (with the date when it isn't today). */
export function viewSubtitle(view: HomeViewSummary, now = new Date(), locale?: string): string {
  const subtitle = text(view.subtitle);
  if (subtitle) return subtitle;
  const date = viewDate(view.refreshedAt) ?? viewDate(view.updatedAt);
  if (!date) return "";
  const today = date.toDateString() === now.toDateString();
  const when = today
    ? date.toLocaleTimeString(locale ?? [], { hour: "numeric", minute: "2-digit" })
    : date.toLocaleString(locale ?? [], { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
  return `Updated ${when}`;
}
