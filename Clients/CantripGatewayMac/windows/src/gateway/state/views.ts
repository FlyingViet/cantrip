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

/** The row's name for screen readers: "Homelab, pinned, private, Updated 3:39 PM". */
export function viewRowLabel(view: HomeViewSummary, now = new Date(), locale?: string): string {
  return [view.name, view.pinned ? "pinned" : "", view.private ? "private" : "", viewSubtitle(view, now, locale)].filter(Boolean).join(", ");
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
