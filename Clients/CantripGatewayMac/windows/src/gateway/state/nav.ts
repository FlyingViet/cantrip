// Window navigation (MacHomeNavigation.swift): Home's sections, the open project tab, and sheets.
import { effect, signal } from "@preact/signals";
import type { DeliveryMode, RemoteSessionSummary } from "../api/types";
import { toast } from "../ui/kit";
import * as remote from "./remote";

export type Section = "chat" | "tasks" | "artifacts";

export const SECTIONS: { id: Section; title: string; icon: "bubble.left.and.bubble.right" | "checklist" | "square.grid.2x2" }[] = [
  { id: "chat", title: "Chat", icon: "bubble.left.and.bubble.right" },
  { id: "tasks", title: "Tasks", icon: "checklist" },
  { id: "artifacts", title: "Artifacts", icon: "square.grid.2x2" },
];

export type SheetState =
  | { kind: "background"; focusSessionID?: string }
  | { kind: "rename"; sessionID: string }
  | { kind: "modelSettings"; sessionID: string }
  | { kind: "inputRequests"; sessionID: string }
  | { kind: "macAccess" }
  | { kind: "usage" }
  | { kind: "memory" }
  | { kind: "builds" }
  | { kind: "mascot" }
  | { kind: "maintenance" }
  | { kind: "voiceMode" }
  | { kind: "queue"; sessionID: string }
  | { kind: "backgroundTasks"; sessionID: string }
  | { kind: "promptReader"; title: string; text: string };

function persisted<T>(key: string, initial: T) {
  let value = initial;
  try {
    const raw = localStorage.getItem(key);
    if (raw !== null) value = JSON.parse(raw) as T;
  } catch { /* first launch */ }
  const state = signal<T>(value);
  effect(() => {
    try { localStorage.setItem(key, JSON.stringify(state.value)); } catch { /* storage full */ }
  });
  return state;
}

export const section = signal<Section>("chat");
/** The project tab shown in the detail pane; null shows Home's section. */
export const openTabID = signal<string | null>(null);
export const sheet = signal<SheetState | null>(null);
export const sidebarHidden = persisted("gateway.sidebarHidden", false);
/** Same key as the Mac app ("hermes.paused"): no requests are sent while paused. */
export const paused = persisted("hermes.paused", false);
/** How the next message reaches a working tab; back to Auto after each send (like the Mac). */
export const deliveryMode = signal<DeliveryMode>("auto");
/** Text to put in the composer when Chat opens (Tasks/Artifacts "+"). */
export const composerPrefill = signal<string | null>(null);
/** Bumped to move keyboard focus into the composer. */
export const composerFocusRequest = signal(0);
/** The question a chat reply answers, when the user picked one (else the first). */
export const chosenQuestion = signal<{ sessionID: string; requestID: string } | null>(null);

// The chat shows the open tab, else Home; Home's tasks/artifacts refresh only while Home shows.
effect(() => {
  const target = openTabID.value ?? remote.homeID.value ?? null;
  remote.setHomeDataWanted(openTabID.value === null);
  remote.select(target);
});

// A tab closed elsewhere (the Mac, another device) returns to Home. Only a list requested after
// the tab opened counts, so a list already in flight can't close a tab that was just created.
let openedTab: string | null = null;
let openedAt = 0;
effect(() => {
  const id = openTabID.value;
  if (id !== openedTab) {
    openedTab = id;
    openedAt = Date.now();
  }
  if (id && remote.listed.value && remote.listedAt.value > openedAt && !remote.sessions.value.some((item) => item.id === id)) {
    openTabID.value = null;
    deliveryMode.value = "auto";
  }
});

export const isTabOpen = (): boolean => openTabID.value !== null;

export function closeAll(): void {
  sheet.value = null;
}

export function openTab(id: string): void {
  closeAll();
  if (openTabID.value !== id) deliveryMode.value = "auto";
  openTabID.value = id;
  composerFocusRequest.value++;
}

export function showHome(target?: Section): void {
  if (target) section.value = target;
  if (openTabID.value !== null) {
    openTabID.value = null;
    deliveryMode.value = "auto";
  }
}

export function openChat(prefill?: string): void {
  showHome("chat");
  if (prefill !== undefined) composerPrefill.value = prefill;
  composerFocusRequest.value++;
}

export function showBackground(focusSessionID?: string): void {
  showHome();
  sheet.value = { kind: "background", focusSessionID };
}

export async function createTab(): Promise<void> {
  if (remote.isMutating.value || !remote.listed.value) return;
  try {
    const session = await remote.createTab();
    openTab(session.id);
  } catch (error) {
    toast(`Couldn't open a new tab: ${(error as Error).message}`);
  }
}

/** Closes a tab; closing the open one returns to Home. */
export async function closeTab(id: string): Promise<void> {
  const wasOpen = openTabID.value === id;
  try {
    await remote.closeTab(id);
    if (wasOpen && openTabID.value === id) showHome();
  } catch (error) {
    toast(`Couldn't close the tab: ${(error as Error).message}`);
  }
}

export function openModelSettings(session: RemoteSessionSummary | null | undefined): void {
  if (!session) return;
  sheet.value = { kind: "modelSettings", sessionID: session.id };
}
