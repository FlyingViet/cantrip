// Thread tags (Cantrip Home), drawn like inline replies in Messages. A reply that belongs to a different thread
// from the message just above it shows a small copy of the prompt that started its thread (the Mac decides which,
// `RemoteMessage.thread`), joined to it by a curved line; a prompt whose replies other messages split up says
// "N Replies" (the Mac's `threadReplies`). Either opens the whole thread over the blurred window, fetched from the
// Mac so it works while the prompt is in older history not loaded yet. The open thread and the fetched threads
// live here, by thread ID, so re-renders, older pages arriving and switching sections don't fetch them again.
import { signal } from "@preact/signals";
import { thread as fetchThread } from "../api/client";
import type { RemoteMessage, RemoteSessionSummary, RemoteThread, RemoteThreadMessage, RemoteThreadTag } from "../api/types";

export type ThreadLoad =
  | { state: "loading" }
  | { state: "loaded"; thread: RemoteThread }
  | { state: "failed"; error: string };

/** The thread on screen. */
export interface ThreadFocus {
  sessionID: string;
  threadID: string;
  /** The prompt as the conversation shows it, until the thread loads. */
  prompt: string;
  /** The reply it was opened from (scrolled into view); null from a prompt's "N Replies". */
  messageID: string | null;
}

/** Fetched threads kept besides the open one. */
const LIMIT = 12;

export const openThread = signal<ThreadFocus | null>(null);
/** Per thread ID. */
export const threadLoads = signal<ReadonlyMap<string, ThreadLoad>>(new Map());
const loads = new Map<string, Promise<void>>();
const stale = new Set<string>();
let generation = 0;

/** The tag a message shows: the Mac sends `thread` only where one belongs, and prompts never show one. */
export function threadTag(message: Pick<RemoteMessage, "role" | "thread">): RemoteThreadTag | null {
  const tag = message.thread;
  return tag?.id && message.role !== "user" ? tag : null;
}

/** The quote's accessible name. */
export function tagLabel(tag: RemoteThreadTag): string {
  return `Reply to: ${tag.prompt}`;
}

export function repliesLabel(count: number): string {
  return count === 1 ? "1 Reply" : `${count} Replies`;
}

/** "N Replies" under a Home prompt whose thread other messages split up; null when it has none to show. */
export function threadReplies(session: RemoteSessionSummary, messageID: string): number | null {
  const count = (session as { threadReplies?: Record<string, number> }).threadReplies?.[messageID];
  return typeof count === "number" && count > 0 ? count : null;
}

/** Who wrote a message in a thread; prompts and answers (`user`) show as bubbles instead. */
export function speaker(message: RemoteThreadMessage, assistantName: string): string {
  if (message.role === "handoff") return "Handoff";
  if (message.role === "error") return "Error";
  const author = message.author?.trim();
  return author ? `${assistantName} · ${author}` : assistantName;
}

export function threadLoad(threadID: string): ThreadLoad | undefined {
  return threadLoads.value.get(threadID);
}

function setLoad(threadID: string, load: ThreadLoad): void {
  const map = new Map(threadLoads.peek());
  map.delete(threadID);
  map.set(threadID, load);
  const open = openThread.peek()?.threadID;
  for (const key of map.keys()) {
    if (map.size <= LIMIT) break;
    if (key !== threadID && key !== open && !loads.has(key)) map.delete(key);
  }
  threadLoads.value = map;
}

/** Opens a thread over the window and fetches it. */
export function showThread(focus: ThreadFocus): void {
  openThread.value = focus;
  void loadThread(focus.sessionID, focus.threadID);
}

export function closeThread(): void {
  openThread.value = null;
}

/**
 * Fetches the whole thread. Replies keep arriving, so it's fetched on every open and whenever the conversation
 * changes while it's open (once more after a fetch already on its way); a failed refresh keeps what's shown.
 */
export function loadThread(sessionID: string, threadID: string): Promise<void> {
  const pending = loads.get(threadID);
  if (pending) {
    stale.add(threadID);
    return pending;
  }
  const started = generation;
  if (threadLoads.peek().get(threadID)?.state !== "loaded") setLoad(threadID, { state: "loading" });
  const work = fetchThread(sessionID, threadID).then(
    (thread) => {
      if (started === generation) setLoad(threadID, { state: "loaded", thread });
    },
    (error: Error) => {
      if (started === generation && threadLoads.peek().get(threadID)?.state !== "loaded") {
        setLoad(threadID, { state: "failed", error: error.message || "The Mac didn't send it." });
      }
    },
  ).finally(() => {
    if (loads.get(threadID) === work) loads.delete(threadID);
    if (stale.delete(threadID) && started === generation && openThread.peek()?.threadID === threadID) void loadThread(sessionID, threadID);
  });
  loads.set(threadID, work);
  return work;
}

/** Forgets every thread and closes the open one (pairing with a different Mac). */
export function resetThreads(): void {
  generation++;
  loads.clear();
  stale.clear();
  threadLoads.value = new Map();
  openThread.value = null;
}
