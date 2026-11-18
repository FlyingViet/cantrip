// Cantrip Home's Views (Cantrip's docs/views.md): the API's paths, reading what the Mac sends leniently, the
// list's order and labels, the open view's refresh loop and what an action's result asks the client to do.
// No DOM or signals, so vitest covers all of it.
import type { HomeTasksSnapshot, HomeViewActionResponse, HomeViewResponse, HomeViewSummary, RemoteCardDocument } from "../api/types";
import { APPLE_EPOCH } from "./format";

/** `refreshAfter` when the Mac sends none. */
export const VIEW_REFRESH_MS = 60_000;
/** Bounds on the Mac's `refreshAfter`, so a bad value can't hammer the Mac or never refresh. */
export const VIEW_MIN_REFRESH_MS = 10_000;
export const VIEW_MAX_REFRESH_MS = 3_600_000;
/** After a failed fetch the view stays as it was and the client asks again this much later. */
export const VIEW_RETRY_MS = 60_000;

const VIEWS = "/api/v1/home/views";

function isObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function component(value: string): string {
  return encodeURIComponent(value);
}

/** Whether the Mac serves Views: clients show them only then. */
export function supportsViews(snapshot: Pick<HomeTasksSnapshot, "supportsViews"> | null | undefined): boolean {
  return snapshot?.supportsViews === true;
}

/** `GET /api/v1/home/views[?revision=]`. */
export function viewsPath(revision?: string | null): string {
  return revision ? `${VIEWS}?revision=${component(revision)}` : VIEWS;
}

/** `GET`/`DELETE /api/v1/home/views/<id>`, and `…/refresh`, `…/pin`, `…/actions/<action id>` with `suffix`. */
export function viewPath(id: string, suffix?: "refresh" | "pin"): string {
  return `${VIEWS}/${component(id)}${suffix ? `/${suffix}` : ""}`;
}

export function viewActionPath(id: string, actionID: string): string {
  return `${VIEWS}/${component(id)}/actions/${component(actionID)}`;
}

/** The body every action post carries: the user confirmed it on this PC. */
export const CONFIRMED_ACTION = { confirmed: true } as const;

function text(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value : undefined;
}

/** A summary the list can show, or null for something that isn't one. */
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

/** The views list answer: the views to show and the revision to ask with next, or `unchanged`. */
export function parseViews(data: unknown): { unchanged: true; revision: string | null } | { unchanged: false; views: HomeViewSummary[]; revision: string | null } {
  if (!isObject(data)) throw new Error("The Mac sent no views.");
  const revision = text(data.revision) ?? null;
  if (data.unchanged === true) return { unchanged: true, revision };
  if (!Array.isArray(data.views)) throw new Error("The Mac sent no views.");
  const views = data.views.map(viewSummary).filter((view): view is HomeViewSummary => view !== null);
  return { unchanged: false, views: orderedViews(views), revision };
}

function isCard(value: unknown): value is RemoteCardDocument {
  return isObject(value) && (Array.isArray(value.blocks) || typeof value.fallbackText === "string");
}

/** When to fetch an open view again: the Mac's `refreshAfter` seconds within bounds, else a minute. */
export function viewRefreshDelay(refreshAfter: unknown): number {
  if (typeof refreshAfter !== "number" || !Number.isFinite(refreshAfter) || refreshAfter <= 0) return VIEW_REFRESH_MS;
  return Math.min(VIEW_MAX_REFRESH_MS, Math.max(VIEW_MIN_REFRESH_MS, Math.round(refreshAfter * 1000)));
}

export interface ShownView {
  view: HomeViewSummary;
  card: RemoteCardDocument;
  refreshMs: number;
}

/** A view answer (`GET`, `POST …/refresh`), or a thrown error when it isn't one. */
export function parseView(data: unknown): ShownView {
  if (!isObject(data)) throw new Error("The Mac sent no view.");
  const view = viewSummary(data.view);
  if (!view || !isCard(data.card)) throw new Error("The Mac sent an incomplete view.");
  return { view, card: data.card, refreshMs: viewRefreshDelay((data as Partial<HomeViewResponse>).refreshAfter) };
}

/** What an action's result asks this PC to do (docs/views.md); anything it can't act on says so. */
export type ViewActionOutcome =
  | { kind: "open"; url: string }
  | { kind: "record"; taskID: string; recordID?: string }
  | { kind: "started"; message: string }
  | { kind: "refreshed"; shown: ShownView | null }
  | { kind: "sent"; message?: string }
  | { kind: "unknown"; message: string };

/** Only web pages open from a view; anything else (file, javascript, a custom scheme) is refused. */
export function viewOpenURL(value: unknown): string | null {
  if (typeof value !== "string" || value.length > 2048) return null;
  try {
    const url = new URL(value);
    return url.protocol === "https:" || url.protocol === "http:" ? url.toString() : null;
  } catch {
    return null;
  }
}

export function viewActionOutcome(data: unknown): ViewActionOutcome {
  const answer = (isObject(data) ? data : {}) as Partial<HomeViewActionResponse>;
  switch (answer.result) {
    case "open": {
      const url = viewOpenURL(answer.url);
      return url ? { kind: "open", url } : { kind: "unknown", message: "That link can't open from this PC." };
    }
    case "record":
      return text(answer.taskID)
        ? { kind: "record", taskID: answer.taskID!, recordID: text(answer.recordID) }
        : { kind: "unknown", message: "The Mac didn't say which record to show." };
    case "started":
      return { kind: "started", message: text(answer.message) ?? "Started on your Mac." };
    case "refreshed": {
      let shown: ShownView | null = null;
      try { shown = parseView(answer); } catch { shown = null; }
      return { kind: "refreshed", shown };
    }
    case "sent":
      return { kind: "sent", message: text(answer.message) };
    default:
      return { kind: "unknown", message: "The Mac answered with something this PC can't show. Update Cantrip Gateway." };
  }
}

/** A view time: ISO 8601, or Apple reference seconds. */
export function viewDate(value: unknown): Date | null {
  if (typeof value === "number" && Number.isFinite(value)) return new Date((value + APPLE_EPOCH) * 1000);
  if (typeof value !== "string" || !value) return null;
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? null : date;
}

/** The list row's second line: the view's subtitle, else "Updated 3:39 PM" (a date when it isn't today). */
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

/** The row's name for screen readers: "Homelab, pinned, private, Updated 3:39 PM, refreshing, 1 problem". */
export function viewRowLabel(view: HomeViewSummary, now = new Date(), locale?: string): string {
  const problems = Array.isArray(view.problems) ? view.problems.filter((problem) => typeof problem === "string" && problem.trim()).length : 0;
  return [
    view.name, view.pinned ? "pinned" : "", view.private ? "private" : "", viewSubtitle(view, now, locale),
    view.refreshing === true ? "refreshing" : "", problems ? `${problems} ${problems === 1 ? "problem" : "problems"}` : "",
  ].filter(Boolean).join(", ");
}

/** A view's first problem, for the line under its thumbnail. */
export function viewProblem(view: HomeViewSummary): string | null {
  return (Array.isArray(view.problems) ? view.problems : []).map(text).find((problem) => problem !== undefined) ?? null;
}

// MARK: The views grid (the views grid spec): columns and thumbnails

/** Space between thumbnails, in pixels. */
export const VIEW_GRID_GAP = 12;
/** Below this width the grid is compact: narrower and shorter thumbnails. */
export const VIEW_GRID_COMPACT_WIDTH = 600;

/** How many thumbnails fit across a grid `width` pixels wide (its content box): 1 to 6. */
export function viewColumns(width: number): number {
  if (!Number.isFinite(width) || width <= 0) return 1;
  const minimum = width < VIEW_GRID_COMPACT_WIDTH ? 160 : 240;
  return Math.min(6, Math.max(1, Math.floor((width + VIEW_GRID_GAP) / (minimum + VIEW_GRID_GAP))));
}

/** A view's last answer on this PC and when it arrived (ms). Thumbnails and the view's screen share these. */
export interface CachedView {
  shown: ShownView;
  fetchedAt: number;
}

function stamp(value: unknown): number | null {
  return viewDate(value)?.getTime() ?? null;
}

/**
 * When a thumbnail's view should be fetched again (ms): now (-Infinity) with nothing cached or when the list's
 * updatedAt/refreshedAt moved past the cached answer's, else once its `refreshAfter` runs out.
 */
export function thumbnailDueAt(summary: HomeViewSummary, cached: CachedView | undefined): number {
  if (!cached) return -Infinity;
  const view = cached.shown.view;
  if (stamp(summary.updatedAt) !== stamp(view.updatedAt) || stamp(summary.refreshedAt) !== stamp(view.refreshedAt)) return -Infinity;
  return cached.fetchedAt + cached.shown.refreshMs;
}

/** Whether a thumbnail needs `GET /api/v1/home/views/<id>` at `now`. */
export function thumbnailNeedsFetch(summary: HomeViewSummary, cached: CachedView | undefined, now: number): boolean {
  return thumbnailDueAt(summary, cached) <= now;
}

/** Thumbnail requests at once. */
export const THUMBNAIL_MAX_IN_FLIGHT = 2;

/**
 * Keeps the listed views' thumbnails current while the grid shows: fetches each view with nothing cached, a changed
 * summary or an elapsed `refreshAfter`, at most two at a time, in list order, and checks again when the next one is
 * due. A failed fetch waits a minute. It only ever reads (`GET`); it never asks the Mac to refresh a view.
 */
export class ThumbnailLoader {
  private views: HomeViewSummary[] = [];
  private readonly inFlight = new Set<string>();
  private readonly failedAt = new Map<string, number>();
  private timer: unknown = null;
  private paused = false;
  private stopped = false;

  constructor(private readonly options: {
    load: (id: string) => Promise<unknown>;
    cached: (id: string) => CachedView | undefined;
    onView: (id: string, shown: ShownView) => void;
    now?: () => number;
    timers?: PollerTimers;
    maxInFlight?: number;
  }) {}

  /** The views being fetched now. */
  get loading(): ReadonlySet<string> {
    return this.inFlight;
  }

  /** The views the grid lists now (pinned first): fetches the ones that are due. */
  update(views: HomeViewSummary[]): void {
    this.views = views;
    this.pump();
  }

  /** Stops asking while the grid can't be seen (requests already sent still land); `resume` picks up again. */
  pause(): void {
    this.paused = true;
    this.clearTimer();
  }

  resume(): void {
    this.paused = false;
    this.pump();
  }

  stop(): void {
    this.stopped = true;
    this.clearTimer();
  }

  private now(): number {
    return (this.options.now ?? Date.now)();
  }

  private get timers(): PollerTimers {
    return this.options.timers ?? defaultTimers;
  }

  private clearTimer(): void {
    if (this.timer !== null) this.timers.clear(this.timer);
    this.timer = null;
  }

  private dueAt(view: HomeViewSummary): number {
    const failed = this.failedAt.get(view.id);
    return Math.max(failed === undefined ? -Infinity : failed + VIEW_RETRY_MS, thumbnailDueAt(view, this.options.cached(view.id)));
  }

  private pump(): void {
    this.clearTimer();
    if (this.stopped || this.paused) return;
    const limit = this.options.maxInFlight ?? THUMBNAIL_MAX_IN_FLIGHT;
    const now = this.now();
    let next = Infinity;
    for (const view of this.views) {
      if (this.inFlight.has(view.id)) continue;
      const due = this.dueAt(view);
      if (due > now) next = Math.min(next, due);
      else if (this.inFlight.size < limit) this.fetch(view.id);
    }
    // A full queue picks up again as each request lands; otherwise wake for the next view that comes due.
    if (this.inFlight.size < limit && Number.isFinite(next)) {
      this.timer = this.timers.set(() => {
        this.timer = null;
        this.pump();
      }, Math.max(0, next - now));
    }
  }

  private fetch(id: string): void {
    this.inFlight.add(id);
    void this.options.load(id)
      .then((data) => {
        const shown = parseView(data);
        this.failedAt.delete(id);
        this.options.onView(id, shown);
      })
      .catch(() => { this.failedAt.set(id, this.now()); })
      .finally(() => {
        this.inFlight.delete(id);
        this.pump();
      });
  }
}

export interface PollerTimers {
  set: (callback: () => void, ms: number) => unknown;
  clear: (handle: unknown) => void;
}

const defaultTimers: PollerTimers = {
  set: (callback, ms) => setTimeout(callback, ms),
  clear: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
};

/**
 * Fetches an open view now and again every `refreshAfter` seconds (a minute after a failure) until stopped.
 * Answers that arrive after `stop()` are dropped, so a closed view never updates or schedules again.
 */
export class ViewPoller {
  private timer: unknown = null;
  private stopped = false;
  private started = false;

  constructor(private readonly options: {
    load: () => Promise<unknown>;
    onView: (shown: ShownView) => void;
    onError?: (error: unknown) => void;
    timers?: PollerTimers;
  }) {}

  get scheduled(): boolean {
    return this.timer !== null;
  }

  start(): void {
    if (this.started || this.stopped) return;
    this.started = true;
    void this.fetch();
  }

  stop(): void {
    this.stopped = true;
    if (this.timer !== null) (this.options.timers ?? defaultTimers).clear(this.timer);
    this.timer = null;
  }

  private async fetch(): Promise<void> {
    let delay = VIEW_RETRY_MS;
    try {
      const shown = parseView(await this.options.load());
      if (this.stopped) return;
      this.options.onView(shown);
      delay = shown.refreshMs;
    } catch (error) {
      if (this.stopped) return;
      this.options.onError?.(error);
    }
    if (this.stopped) return;
    this.timer = (this.options.timers ?? defaultTimers).set(() => {
      this.timer = null;
      void this.fetch();
    }, delay);
  }
}
