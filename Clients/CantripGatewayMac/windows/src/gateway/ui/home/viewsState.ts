// The open view's state and the Views requests (docs/views.md): load, Refresh, Pin, Delete and a view's buttons,
// each sent once (never retried) with the result applied to the list and the open view.
import { signal } from "@preact/signals";
import { api } from "../../api/client";
import type { HomeViewSummary } from "../../api/types";
import { bridge } from "../../bridge";
import * as nav from "../../state/nav";
import * as remote from "../../state/remote";
import {
  CONFIRMED_ACTION, orderedViews, parseView, viewActionOutcome, viewActionPath, viewPath, viewSummary, type CachedView, type ShownView,
  type ViewActionOutcome,
} from "../../state/views";
import { toast } from "../kit";
import type { CardButtonModel } from "../transcript/cardLogic";
import * as tasksNav from "./tasksNav";

export interface OpenViewState {
  id: string;
  /** The last answer; it stays through a failed refresh. */
  shown: ShownView | null;
  loading: boolean;
  refreshing: boolean;
  error: string | null;
}

/** The view whose screen is open. */
export const openView = signal<OpenViewState | null>(null);
/**
 * Each view's last answer this run and when it came: the grid's thumbnails draw it, and reopening a view shows it at
 * once while it loads. The view's screen, its Refresh and the thumbnails all keep it current.
 */
export const viewDetails = signal<ReadonlyMap<string, CachedView>>(new Map());
/** More than the Mac keeps (30 views), so a listed view's answer is never dropped. */
const MAX_CACHED_VIEWS = 40;

function forget(id: string): void {
  if (!viewDetails.peek().has(id)) return;
  const next = new Map(viewDetails.peek());
  next.delete(id);
  viewDetails.value = next;
}

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function update(id: string, change: Partial<OpenViewState>): void {
  const current = openView.value;
  if (current?.id === id) openView.value = { ...current, ...change };
}

function replaceSummary(summary: HomeViewSummary): void {
  const list = remote.homeViews.value;
  if (!list?.some((view) => view.id === summary.id)) return;
  remote.homeViews.value = orderedViews(list.map((view) => (view.id === summary.id ? summary : view)));
}

/** Opens a view's screen with what this PC last saw of it. */
export function showView(id: string): void {
  const cached = viewDetails.peek().get(id)?.shown ?? null;
  openView.value = { id, shown: cached, loading: !cached, refreshing: false, error: null };
}

export function closeView(id: string): void {
  if (openView.value?.id === id) openView.value = null;
}

/** A fresh answer for a view: cached for its thumbnail, shown if its screen is open, and its row updated. */
export function applyShown(id: string, shown: ShownView, fetchedAt = Date.now()): void {
  const next = new Map(viewDetails.peek());
  next.delete(id);
  next.set(id, { shown, fetchedAt });
  while (next.size > MAX_CACHED_VIEWS) next.delete(next.keys().next().value!);
  viewDetails.value = next;
  update(id, { shown, loading: false, error: null });
  replaceSummary(shown.view);
}

export function loadFailed(id: string, error: unknown): void {
  update(id, { loading: false, error: `Couldn't load this view: ${message(error)}` });
}

/** `GET /api/v1/home/views/<id>` (the open view's poller and the grid's thumbnails). */
export function fetchView(id: string): Promise<unknown> {
  return api<unknown>(viewPath(id));
}

/** Refresh: the Mac reads the view's tool sources again (up to 20 s) and answers with the view. */
export async function refreshView(id: string): Promise<boolean> {
  if (openView.value?.id === id && openView.value.refreshing) return false;
  update(id, { refreshing: true, error: null });
  try {
    applyShown(id, parseView(await api<unknown>(viewPath(id, "refresh"), { method: "POST" })));
    return true;
  } catch (error) {
    update(id, { error: `Couldn't refresh this view: ${message(error)}` });
    return false;
  } finally {
    update(id, { refreshing: false });
  }
}

/** Pin or unpin: pinned views come first in the list. */
export async function setViewPinned(view: HomeViewSummary, pinned: boolean): Promise<boolean> {
  try {
    const answer = await remote.mutate(() => api<unknown>(viewPath(view.id, "pin"), { method: "POST", body: { pinned } }));
    const summary = viewSummary(answer) ?? { ...view, pinned };
    replaceSummary(summary);
    const current = openView.value;
    if (current?.id === view.id && current.shown) update(view.id, { shown: { ...current.shown, view: summary } });
    void remote.refreshViews();
    return true;
  } catch (error) {
    update(view.id, { error: `Couldn't ${pinned ? "pin" : "unpin"} this view: ${message(error)}` });
    return false;
  }
}

export async function deleteView(view: HomeViewSummary): Promise<boolean> {
  try {
    await remote.mutate(() => api<unknown>(viewPath(view.id), { method: "DELETE" }));
  } catch (error) {
    update(view.id, { error: `Couldn't delete this view: ${message(error)}` });
    return false;
  }
  forget(view.id);
  const list = remote.homeViews.value;
  if (list) remote.homeViews.value = list.filter((item) => item.id !== view.id);
  closeView(view.id);
  void remote.refreshViews();
  return true;
}

/** Posts a view's button after the user confirmed it (`{"confirmed": true}`); the outcome says what to show next. */
export async function postViewAction(viewID: string, actionID: string): Promise<ViewActionOutcome> {
  return viewActionOutcome(await api<unknown>(viewActionPath(viewID, actionID), { method: "POST", body: CONFIRMED_ACTION }));
}

/** Does what an action's result asks: open the page, show the record, say it started, show the refreshed view, or go to Home's chat. */
export function applyViewOutcome(viewID: string, outcome: ViewActionOutcome): void {
  switch (outcome.kind) {
    case "open":
      bridge.openExternal(outcome.url);
      return;
    case "record": {
      const task = remote.homeTasks.value?.tasks.find((item) => item.id.toUpperCase() === outcome.taskID.toUpperCase());
      if (!task) {
        update(viewID, { error: "That task isn't on this PC yet. Refresh Tasks and try again." });
        return;
      }
      const record = outcome.recordID ? task.workspace?.records.find((item) => item.id.toUpperCase() === outcome.recordID!.toUpperCase()) : undefined;
      if (record) tasksNav.openRecord(task.id, record.id, viewID);
      else if (task.workspace) tasksNav.openWorkspace(task.id);
      else tasksNav.editingTask.value = task;
      return;
    }
    case "started":
      toast(outcome.message);
      return;
    case "refreshed":
      if (outcome.shown) applyShown(viewID, outcome.shown);
      else void fetchView(viewID).then((data) => applyShown(viewID, parseView(data))).catch((error) => loadFailed(viewID, error));
      return;
    case "sent":
      nav.showHome("chat");
      return;
    default:
      update(viewID, { error: outcome.message });
  }
}

/** The handler a view's card runs once a button is confirmed. */
export function viewActionHandler(viewID: string): (button: CardButtonModel) => Promise<void> {
  return async (button) => {
    update(viewID, { error: null });
    try {
      applyViewOutcome(viewID, await postViewAction(viewID, button.id));
    } catch (error) {
      update(viewID, { error: `Couldn't ${button.label.toLowerCase()}: ${message(error)}` });
    }
  };
}
