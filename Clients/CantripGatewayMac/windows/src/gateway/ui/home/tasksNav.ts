// Tasks' in-pane navigation (the Mac pushes a workspace and its records in a NavigationStack), its sheets,
// and where keyboard focus and scrolling return when going back.
import { signal } from "@preact/signals";
import type { HomeTask, HomeTaskRecord } from "../../api/types";

export type TasksRoute =
  | { kind: "list" }
  | { kind: "workspace"; taskID: string }
  | { kind: "record"; taskID: string; recordID: string };

export const route = signal<TasksRoute>({ kind: "list" });
/** The open workspace's search text (kept while a record is open, cleared when another workspace opens). */
export const search = signal("");
/** The task whose Edit Task sheet is open (a snapshot from when it opened). */
export const editingTask = signal<HomeTask | null>(null);
/** The record editor: a new record (null) or a snapshot of the one being edited. */
export const recordEditor = signal<{ taskID: string; record: HomeTaskRecord | null } | null>(null);

/** data-focus-key of the element to focus after the next render (the row a Back returns to). */
let pendingFocus: string | null = null;
const scrolls = new Map<string, number>();

export function openWorkspace(taskID: string): void {
  if (route.value.kind === "list") search.value = "";
  scrolls.delete(`workspace:${taskID}`);
  route.value = { kind: "workspace", taskID };
}

export function openRecord(taskID: string, recordID: string): void {
  scrolls.delete(`record:${taskID}:${recordID}`);
  route.value = { kind: "record", taskID, recordID };
}

export function back(): void {
  const current = route.value;
  if (current.kind === "record") {
    pendingFocus = `record:${current.recordID}`;
    route.value = { kind: "workspace", taskID: current.taskID };
  } else if (current.kind === "workspace") {
    pendingFocus = `task:${current.taskID}`;
    search.value = "";
    route.value = { kind: "list" };
  }
}

/** Focuses the row Back returned to, once it has rendered. */
export function restoreFocus(container: HTMLElement | null): void {
  if (!pendingFocus || !container) return;
  const target = container.querySelector<HTMLElement>(`[data-focus-key="${CSS.escape(pendingFocus)}"]`);
  pendingFocus = null;
  target?.focus();
}

export function savedScroll(key: string): number {
  return scrolls.get(key) ?? 0;
}

export function saveScroll(key: string, top: number): void {
  scrolls.set(key, top);
}
