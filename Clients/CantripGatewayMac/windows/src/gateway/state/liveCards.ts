// Live run cards (Cantrip's docs/remote-control.md, "Live cards"): the tasks list is read with
// `liveCards=separate`, so a task's latest-run forecast comes as stored, marked `live`, and a rebuilt one
// doesn't resend the list; `GET /api/v1/home/live-cards` has the current versions. A live card past
// `staleAfter` (or not fetched yet) is marked `updating` so an old forecast never reads as current.
// No DOM or signals (vitest).
import type { HomeTask, HomeTaskRun, RemoteCardDocument } from "../api/types";
import { APPLE_EPOCH } from "./format";

export const LIVE_CARDS = "/api/v1/home/live-cards";
/** The Mac's defaults, for cards shown before the first read. */
export const LIVE_STALE_AFTER_S = 900;
export const LIVE_WINDOW_S = 86_400;

export interface HomeLiveCards {
  revision: string;
  staleAfter: number;
  liveWindow: number;
  /** By `liveCardKey(runID, cardID)`. */
  cards: ReadonlyMap<string, RemoteCardDocument>;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

export function liveCardKey(runID: string, cardID: string): string {
  return `${runID.toUpperCase()}/${cardID}`;
}

export function tasksPath(revision: string | null): string {
  return `/api/v1/home/tasks?liveCards=separate${revision ? `&revision=${encodeURIComponent(revision)}` : ""}`;
}

export function liveCardsPath(revision: string | null | undefined): string {
  return revision ? `${LIVE_CARDS}?revision=${encodeURIComponent(revision)}` : LIVE_CARDS;
}

/** The Mac's answer; null when it's `unchanged` or unreadable (the cards shown stay). */
export function parseLiveCards(value: unknown): HomeLiveCards | null {
  if (!isObject(value) || value.unchanged === true || typeof value.revision !== "string" || !Array.isArray(value.cards)) return null;
  const cards = new Map<string, RemoteCardDocument>();
  for (const entry of value.cards) {
    if (!isObject(entry) || typeof entry.runID !== "string" || !isObject(entry.card) || typeof entry.card.id !== "string") continue;
    cards.set(liveCardKey(entry.runID, entry.card.id), entry.card as unknown as RemoteCardDocument);
  }
  const seconds = (raw: unknown, fallback: number) => (typeof raw === "number" && raw > 0 ? raw : fallback);
  return { revision: value.revision, staleAfter: seconds(value.staleAfter, LIVE_STALE_AFTER_S),
    liveWindow: seconds(value.liveWindow, LIVE_WINDOW_S), cards };
}

function kept(run: Pick<HomeTaskRun, "finishedAt">, live: HomeLiveCards | null, now: number): boolean {
  return typeof run.finishedAt === "number"
    && now - (run.finishedAt + APPLE_EPOCH) * 1000 < (live?.liveWindow ?? LIVE_WINDOW_S) * 1000;
}

/** Whether any task's latest run has a card the Mac still keeps current. */
export function liveCardsNeeded(tasks: readonly Pick<HomeTask, "runs">[] | undefined, live: HomeLiveCards | null, now = Date.now()): boolean {
  return (tasks ?? []).some((task) => {
    const run = Array.isArray(task.runs) ? task.runs[0] : undefined;
    return !!run && kept(run, live, now) && Array.isArray(run.cards) && run.cards.some((card) => isObject(card) && card.live === true);
  });
}

/** A latest run's cards as they show at `now`: each live one's current version, `updating` while out of date. */
export function shownRunCards(run: Pick<HomeTaskRun, "id" | "finishedAt" | "cards">, live: HomeLiveCards | null, now = Date.now()): unknown[] {
  if (!Array.isArray(run.cards)) return [];
  const current = kept(run, live, now);
  const staleAfter = (live?.staleAfter ?? LIVE_STALE_AFTER_S) * 1000;
  return run.cards.map((card) => {
    if (!isObject(card) || card.live !== true || typeof card.id !== "string") return card;
    const shown = live?.cards.get(liveCardKey(run.id, card.id)) ?? (card as unknown as RemoteCardDocument);
    const updated = new Date(shown.source?.updatedAt ?? "").getTime();
    return { ...shown, updating: current && (Number.isNaN(updated) || now - updated >= staleAfter) };
  });
}

/** Which live cards read as updating: a change re-renders them though nothing new was fetched. */
export function updatingKey(tasks: readonly Pick<HomeTask, "runs">[] | undefined, live: HomeLiveCards | null, now = Date.now()): string {
  return (tasks ?? []).map((task) => {
    const run = Array.isArray(task.runs) ? task.runs[0] : undefined;
    return run ? shownRunCards(run, live, now).filter((card) => isObject(card) && card.updating === true).map((card) => (card as RemoteCardDocument).id).join(",") : "";
  }).join("|");
}
