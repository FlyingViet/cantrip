// Thread tags (Cantrip Home): a reply that belongs to a different thread from the message just above
// it names the prompt that started its thread (the Mac decides which, `RemoteMessage.thread`). The tag
// opens that thread inline, fetched from the Mac so it works while the prompt is in older history not
// loaded yet. Open state and fetched threads live here, per tagged message ID, so re-renders, older
// pages arriving and switching tabs neither collapse a thread nor fetch it again.
import { signal } from "@preact/signals";
import { thread as fetchThread } from "../api/client";
import type { RemoteMessage, RemoteThread, RemoteThreadMessage, RemoteThreadTag } from "../api/types";

export type ThreadLoad =
  | { state: "loading" }
  | { state: "loaded"; thread: RemoteThread }
  | { state: "failed"; error: string };

export interface ThreadView {
  open: boolean;
  load?: ThreadLoad;
}

/** Closed threads kept beyond this many tags are forgotten, oldest first. */
const LIMIT = 60;

/** Per tagged message ID. */
export const threadViews = signal<ReadonlyMap<string, ThreadView>>(new Map());
const loads = new Map<string, Promise<void>>();
let generation = 0;

/** The tag a message shows: the Mac sends `thread` only where one belongs, and prompts never show one. */
export function threadTag(message: Pick<RemoteMessage, "role" | "thread">): RemoteThreadTag | null {
  const tag = message.thread;
  return tag?.id && message.role !== "user" ? tag : null;
}

/** The tag's accessible name. */
export function tagLabel(tag: RemoteThreadTag): string {
  return `Reply to: ${tag.prompt}`;
}

/** The ID of the panel a tag opens (its `aria-controls`). */
export function panelID(messageID: string): string {
  return `thread-${messageID}`;
}

/** Who wrote an earlier message in a thread; prompts and answers (`user`) show as bubbles instead. */
export function speaker(message: RemoteThreadMessage, assistantName: string): string {
  if (message.role === "handoff") return "Handoff";
  if (message.role === "error") return "Error";
  const author = message.author?.trim();
  return author ? `${assistantName} · ${author}` : assistantName;
}

export function threadView(messageID: string): ThreadView {
  return threadViews.value.get(messageID) ?? { open: false };
}

function update(messageID: string, change: (view: ThreadView) => ThreadView): void {
  const map = new Map(threadViews.peek());
  const next = change(map.get(messageID) ?? { open: false });
  map.delete(messageID);
  map.set(messageID, next);
  for (const [key, view] of map) {
    if (map.size <= LIMIT) break;
    if (key !== messageID && !view.open && view.load?.state !== "loading") map.delete(key);
  }
  threadViews.value = map;
}

/** Opens or closes a tag's thread. Opening fetches it the first time, and again after a failure. */
export function toggleThread(sessionID: string, messageID: string, tag: RemoteThreadTag): void {
  const open = !threadViews.peek().get(messageID)?.open;
  update(messageID, (view) => ({ ...view, open }));
  if (open) void loadThread(sessionID, messageID, tag.id);
}

/** Fetches a tag's thread unless it's loaded or loading (Try Again after a failure). */
export function loadThread(sessionID: string, messageID: string, threadID: string): Promise<void> {
  const pending = loads.get(messageID);
  if (pending) return pending;
  if (threadViews.peek().get(messageID)?.load?.state === "loaded") return Promise.resolve();
  const started = generation;
  update(messageID, (view) => ({ ...view, load: { state: "loading" } }));
  const work = fetchThread(sessionID, threadID, messageID).then(
    (thread) => {
      if (started === generation) update(messageID, (view) => ({ ...view, load: { state: "loaded", thread } }));
    },
    (error: Error) => {
      if (started === generation) update(messageID, (view) => ({ ...view, load: { state: "failed", error: error.message || "The Mac didn't send it." } }));
    },
  ).finally(() => {
    if (loads.get(messageID) === work) loads.delete(messageID);
  });
  loads.set(messageID, work);
  return work;
}

/** Forgets every thread (pairing with a different Mac). */
export function resetThreads(): void {
  generation++;
  loads.clear();
  threadViews.value = new Map();
}
