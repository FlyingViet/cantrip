// Home's task and artifact mutations (CantripRemoteModel.updateHomeTask … deleteHomeArtifact): one at a time
// through remote.mutate, never retried, with the Mac's single "home data error" line.
import { computed, effect, signal } from "@preact/signals";
import { api, pathComponent } from "../../api/client";
import type { DeletedResponse, HomeArtifact, HomeTask, HomeTasksSnapshot, HomeTaskUpdateRequest } from "../../api/types";
import * as remote from "../../state/remote";
import { applyMove } from "./homeLogic";
import { forgetThumbnail } from "./thumbnails";

/** The last failed mutation's message; the next completed poll clears it, as the Mac's next refresh does. */
export const mutationError = signal<string | null>(null);

/** What the Mac shows above Tasks and Artifacts: a failed action, a failed fetch, or the Mac's storage problem. */
export const homeDataError = computed(() =>
  mutationError.value ?? remote.homeTasksError.value ?? remote.homeArtifactsError.value ?? remote.homeTasks.value?.error ?? null);

/** Pause/resume switches already flipped while their PATCH is in flight. */
export const pendingEnabled = signal<ReadonlyMap<string, boolean>>(new Map());

let clearAfterPoll = false;
effect(() => {
  if (remote.isRefreshing.value) clearAfterPoll = mutationError.peek() !== null;
  else if (clearAfterPoll) {
    clearAfterPoll = false;
    mutationError.value = null;
  }
});

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

async function perform<T>(work: () => Promise<T>): Promise<T | null> {
  try {
    const result = await remote.mutate(work);
    mutationError.value = null;
    return result;
  } catch (error) {
    mutationError.value = message(error);
    return null;
  }
}

function taskPath(id: string, suffix = ""): string {
  return `/api/v1/home/tasks/${pathComponent(id)}${suffix}`;
}

function replaceTask(updated: HomeTask): void {
  const snapshot = remote.homeTasks.value;
  if (!snapshot?.tasks.some((task) => task.id === updated.id)) return;
  remote.homeTasks.value = { ...snapshot, tasks: snapshot.tasks.map((task) => (task.id === updated.id ? updated : task)) };
}

/** PATCH title, prompt, or enabled (pause/resume). */
export async function updateTask(task: HomeTask, change: HomeTaskUpdateRequest): Promise<boolean> {
  const toggling = change.enabled !== undefined && change.title === undefined && change.prompt === undefined;
  if (toggling) pendingEnabled.value = new Map(pendingEnabled.value).set(task.id, change.enabled!);
  try {
    const updated = await perform(() => api<HomeTask>(taskPath(task.id), { method: "PATCH", body: change }));
    if (!updated) return false;
    replaceTask(updated);
    void remote.refreshTasks();
    return true;
  } finally {
    if (toggling) {
      const map = new Map(pendingEnabled.value);
      map.delete(task.id);
      pendingEnabled.value = map;
    }
  }
}

export async function deleteTask(task: HomeTask): Promise<boolean> {
  const done = await perform(() => api<DeletedResponse>(taskPath(task.id), { method: "DELETE" }));
  if (!done) return false;
  const snapshot = remote.homeTasks.value;
  if (snapshot) remote.homeTasks.value = { ...snapshot, tasks: snapshot.tasks.filter((item) => item.id !== task.id) };
  void remote.refreshTasks();
  return true;
}

/** Applies the move at once so a drop doesn't snap back while the Mac saves; reverts if the Mac refuses. */
export async function moveTask(id: string, targetID: string, after: boolean): Promise<boolean> {
  if (id === targetID) return true;
  const snapshot = remote.homeTasks.value;
  if (!snapshot) return false;
  if (snapshot.supportsReordering !== true) {
    mutationError.value = "Update Cantrip on the Mac to reorder tasks.";
    return false;
  }
  if (remote.isMutating.value) return false;
  const preview = applyMove(snapshot.tasks, id, targetID, after);
  if (!preview) {
    mutationError.value = "A task changed on the Mac. Refresh Tasks and try again.";
    return false;
  }
  if (preview.every((task, index) => task.id === snapshot.tasks[index].id)) return true;
  const shown = { ...snapshot, tasks: preview };
  remote.homeTasks.value = shown;
  try {
    const result = await remote.mutate(() => api<HomeTasksSnapshot>(taskPath(id, "/move"), {
      method: "POST", body: { targetID, placement: after ? "after" : "before" },
    }));
    remote.homeTasks.value = result;
    mutationError.value = null;
    return true;
  } catch (error) {
    if (remote.homeTasks.value === shown) remote.homeTasks.value = snapshot;
    mutationError.value = message(error);
    return false;
  }
}

/** Moves a task one place up (-1) or down (1), like the Mac's Move up / Move down actions. */
export function moveTaskBy(id: string, offset: -1 | 1): Promise<boolean> {
  const tasks = remote.homeTasks.value?.tasks ?? [];
  const index = tasks.findIndex((task) => task.id === id);
  const target = tasks[index + offset];
  if (index < 0 || !target) return Promise.resolve(false);
  return moveTask(id, target.id, offset > 0);
}

/** Creates (recordID null) or updates a workspace record. */
export async function saveRecord(taskID: string, recordID: string | null, values: Record<string, string>): Promise<boolean> {
  const path = recordID ? taskPath(taskID, `/records/${pathComponent(recordID)}`) : taskPath(taskID, "/records");
  const updated = await perform(() => api<HomeTask>(path, { method: recordID ? "PATCH" : "POST", body: { values } }));
  if (!updated) return false;
  replaceTask(updated);
  void remote.refreshTasks();
  return true;
}

export async function deleteRecord(taskID: string, recordID: string): Promise<boolean> {
  const updated = await perform(() => api<HomeTask>(taskPath(taskID, `/records/${pathComponent(recordID)}`), { method: "DELETE" }));
  if (!updated) return false;
  replaceTask(updated);
  void remote.refreshTasks();
  return true;
}

export async function deleteArtifact(artifact: HomeArtifact): Promise<boolean> {
  const done = await perform(() => api<DeletedResponse>(`/api/v1/home/artifacts/${pathComponent(artifact.id)}`, { method: "DELETE" }));
  if (!done) return false;
  forgetThumbnail(artifact);
  const snapshot = remote.homeArtifacts.value;
  if (snapshot) remote.homeArtifacts.value = { ...snapshot, artifacts: snapshot.artifacts.filter((item) => item.id !== artifact.id) };
  void remote.refreshArtifacts();
  return true;
}

/** Whether Home's chat session is showing, and what to say when it isn't (CantripHomeChatAvailability). */
export function homeAvailability(): { state: "ready" } | { state: "opening" } | { state: "unavailable"; message: string } {
  if (remote.selectedSession.value?.isCantripHome === true) return { state: "ready" };
  const detail = remote.detailError.value;
  if (detail) return { state: "unavailable", message: detail };
  if (remote.listed.value && remote.homeSummary.value === null) {
    return { state: "unavailable", message: "Enable Cantrip Home in the Mac app's settings." };
  }
  return { state: "opening" };
}
