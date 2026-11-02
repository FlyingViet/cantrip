// Cards on Cantrip Home (Cantrip's docs/cantrip-home.md, "Workspace cards" and "Background runs"): which
// cards a run, a workspace and a record show, and the record cards' refresh loop. Everything the Mac sends
// is read leniently, so a malformed card is skipped and never breaks a list. No DOM or signals (vitest).
import type {
  HomeBackgroundRun, HomeTask, HomeTaskCardSpec, HomeTaskRun, HomeTasksSnapshot, HomeTaskWorkspace, RemoteCardDocument,
} from "../../api/types";

/** More than the Mac sends (4 per run, 4 per workspace), so a broken host can't flood a list. */
export const MAX_CARDS = 8;
/** `refreshAfter` when the Mac sends none (the Mac's own default). */
export const RECORD_CARDS_REFRESH_MS = 300_000;
/** Bounds on the Mac's `refreshAfter`, so a bad value can't hammer the Mac or never refresh. */
export const RECORD_CARDS_MIN_REFRESH_MS = 15_000;
export const RECORD_CARDS_MAX_REFRESH_MS = 3_600_000;
/** After a failed fetch the last cards stay and the client asks again this much later. */
export const RECORD_CARDS_RETRY_MS = 60_000;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function isObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

/** Something the card renderer can take: an object with blocks or a plain-text fallback. */
export function isCardDocument(value: unknown): value is RemoteCardDocument {
  return isObject(value) && (Array.isArray(value.blocks) || typeof value.fallbackText === "string");
}

/** The cards in `value` (anything the Mac sent), skipping entries that aren't cards. */
export function cardDocuments(value: unknown): RemoteCardDocument[] {
  return Array.isArray(value) ? value.filter(isCardDocument).slice(0, MAX_CARDS) : [];
}

/** A task run's cards. */
export function runCards(run: Pick<HomeTaskRun, "cards"> | null | undefined): RemoteCardDocument[] {
  return isObject(run) ? cardDocuments(run.cards) : [];
}

/** A Background run's cards: only once it has finished (the Mac sends none while it runs). */
export function backgroundRunCards(run: Pick<HomeBackgroundRun, "status" | "cards"> | null | undefined): RemoteCardDocument[] {
  return isObject(run) && run.status !== "running" ? cardDocuments(run.cards) : [];
}

/** The task's latest run when it has cards. */
export function latestRunCards(task: Pick<HomeTask, "runs">): { run: HomeTaskRun; cards: RemoteCardDocument[] } | null {
  const run = Array.isArray(task.runs) ? task.runs[0] : undefined;
  const cards = runCards(run);
  return run && cards.length ? { run, cards } : null;
}

/** The `list` cards the Mac built from a workspace's records (`workspaceCards[taskID]`). */
export function workspaceCards(snapshot: Pick<HomeTasksSnapshot, "workspaceCards"> | null | undefined, taskID: string): RemoteCardDocument[] {
  const byTask: unknown = snapshot?.workspaceCards;
  if (!isObject(byTask)) return [];
  if (Object.prototype.hasOwnProperty.call(byTask, taskID)) return cardDocuments(byTask[taskID]);
  const id = taskID.toUpperCase();
  const key = Object.keys(byTask).find((candidate) => candidate.toUpperCase() === id);
  return key ? cardDocuments(byTask[key]) : [];
}

/** What a workspace shows above its records: its own cards, then its latest run's (none while searching). */
export interface WorkspaceCardsView {
  workspace: RemoteCardDocument[];
  latest: { run: HomeTaskRun; cards: RemoteCardDocument[] } | null;
}

export function workspaceCardsView(
  snapshot: Pick<HomeTasksSnapshot, "workspaceCards"> | null | undefined,
  task: Pick<HomeTask, "id" | "runs">,
  searching: boolean,
): WorkspaceCardsView | null {
  if (searching) return null;
  const workspace = workspaceCards(snapshot, task.id);
  const latest = latestRunCards(task);
  return workspace.length || latest ? { workspace, latest } : null;
}

/** The workspace's card specs the client can read. */
export function workspaceCardSpecs(workspace: Pick<HomeTaskWorkspace, "cards"> | null | undefined): HomeTaskCardSpec[] {
  const specs: unknown = workspace?.cards;
  return Array.isArray(specs) ? specs.filter((spec): spec is HomeTaskCardSpec => isObject(spec) && typeof spec.kind === "string") : [];
}

/** Which live cards a record's detail asks the Mac for: none unless the workspace has a weather or map card. */
export function recordCardKinds(workspace: Pick<HomeTaskWorkspace, "cards"> | null | undefined): { weather: boolean; map: boolean } {
  const kinds = new Set(workspaceCardSpecs(workspace).map((spec) => spec.kind));
  return { weather: kinds.has("weather"), map: kinds.has("map") };
}

export function wantsRecordCards(workspace: Pick<HomeTaskWorkspace, "cards"> | null | undefined): boolean {
  const kinds = recordCardKinds(workspace);
  return kinds.weather || kinds.map;
}

/** The record cards region's name for screen readers ("Forecast and map for Winter Lights Weekend"). */
export function recordCardsLabel(workspace: Pick<HomeTaskWorkspace, "cards"> | null | undefined, title: string): string {
  const kinds = recordCardKinds(workspace);
  const what = kinds.weather && kinds.map ? "Forecast and map" : kinds.weather ? "Forecast" : kinds.map ? "Map" : "Cards";
  return title.trim() ? `${what} for ${title.trim()}` : what;
}

/** `GET /api/v1/home/tasks/<task>/records/<record>/cards`, or null unless both IDs are UUIDs. */
export function recordCardsPath(taskID: unknown, recordID: unknown): string | null {
  if (typeof taskID !== "string" || typeof recordID !== "string" || !UUID.test(taskID) || !UUID.test(recordID)) return null;
  return `/api/v1/home/tasks/${taskID}/records/${recordID}/cards`;
}

/** When to ask again: the Mac's `refreshAfter` seconds within bounds, else 5 minutes. */
export function recordCardsDelay(refreshAfter: unknown): number {
  if (typeof refreshAfter !== "number" || !Number.isFinite(refreshAfter) || refreshAfter <= 0) return RECORD_CARDS_REFRESH_MS;
  return Math.min(RECORD_CARDS_MAX_REFRESH_MS, Math.max(RECORD_CARDS_MIN_REFRESH_MS, Math.round(refreshAfter * 1000)));
}

/** The record cards answer, or a thrown error when it isn't one (the last cards stay). */
export function parseRecordCards(data: unknown): { cards: RemoteCardDocument[]; refreshMs: number } {
  if (!isObject(data) || !Array.isArray(data.cards)) throw new Error("The Mac sent no cards.");
  return { cards: cardDocuments(data.cards), refreshMs: recordCardsDelay(data.refreshAfter) };
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
 * Fetches a record's cards now and again every `refreshAfter` seconds (60 s after a failure) until stopped.
 * Answers that arrive after `stop()` are dropped, so a closed detail never updates or schedules again.
 */
export class RecordCardsPoller {
  private timer: unknown = null;
  private stopped = false;
  private started = false;

  constructor(private readonly options: {
    load: () => Promise<unknown>;
    onCards: (cards: RemoteCardDocument[]) => void;
    onError?: (error: unknown) => void;
    timers?: PollerTimers;
  }) {}

  /** Whether a refetch is scheduled. */
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
    let delay = RECORD_CARDS_RETRY_MS;
    try {
      const parsed = parseRecordCards(await this.options.load());
      if (this.stopped) return;
      this.options.onCards(parsed.cards);
      delay = parsed.refreshMs;
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
