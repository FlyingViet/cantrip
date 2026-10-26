// The paired Mac's state, polled like the Mac app's CantripRemoteModel (CantripRemote.swift):
// the tab list every 1.5 s while busy / 5 s idle / 15 s behind other windows, the shown session's
// transcript only when its historyRevision changes, and Home's tasks and artifacts with revisions.
import { batch, computed, signal } from "@preact/signals";
import { api, APIError, onWritesChanged, pathComponent } from "../api/client";
import type {
  ChildTabAction, ForkQueuedResponse, HomeArtifactsResponse, HomeArtifactsSnapshot, HomeBackgroundSnapshot, HomeInputGroup, HomeTasksResponse,
  HomeTasksSnapshot, InputAnswerRequest, MoveTabResponse, PagedRemoteSessionDetail, RemoteMessage,
  RemoteSessionSummary, SendMessageRequest, SessionResponse, SessionsListResponse, SessionUpdateResponse,
  SubagentCancelResponse, TabSection, TabSectionsResponse,
} from "../api/types";
import { bridge, type HostStatus } from "../bridge";
import { movedSections } from "./sections";
import { plainMentions, plainMentionsDeep, plainSession } from "./tabMentions";
import { resetThreads } from "./threads";

export type Detail = PagedRemoteSessionDetail;

export type ConnectionState = "connecting" | "connected" | "reconnecting";

export const connection = signal<{ state: ConnectionState; route: string; message: string }>({
  state: "connecting", route: bridge.status.route, message: "",
});
export const hostStatus = signal<HostStatus>(bridge.status);
export const sessions = signal<RemoteSessionSummary[]>([]);
/** Sections the Mac groups its tabs into, in order (empty: one flat list). */
export const tabSections = signal<TabSection[]>([]);
export const supportsTabSections = signal(false);
export const homeSummary = signal<RemoteSessionSummary | null>(null);
export const homeInputs = signal<HomeInputGroup[]>([]);
export const listed = signal(false);
/** When the request behind the current `sessions` list started (ms). */
export const listedAt = signal(0);
export const details = signal<ReadonlyMap<string, Detail>>(new Map());
/** The session the chat shows: Home's, or the open tab's. */
export const selectedID = signal<string | null>(null);
export const errorMessage = signal<string | null>(null);
export const detailError = signal<string | null>(null);
export const isMutating = signal(false);
export const isRefreshing = signal(false);
export const pendingWrites = signal(0);
export const stoppingID = signal<string | null>(null);
export const homeTasks = signal<HomeTasksSnapshot | null>(null);
export const homeTasksError = signal<string | null>(null);
export const homeArtifacts = signal<HomeArtifactsSnapshot | null>(null);
export const homeArtifactsError = signal<string | null>(null);
export const homeBackground = signal<HomeBackgroundSnapshot | null>(null);
export const homeBackgroundError = signal<string | null>(null);
/** Per session: loading older history, or why it failed (automatic loading then waits for Retry). */
export const historyState = signal<ReadonlyMap<string, { loading: boolean; error: string | null }>>(new Map());
/** Sessions whose older history the user loaded; polls then keep it instead of trimming. */
const expanded = new Set<string>();
/** Answered background-run requests, hidden until the next poll stops listing them. */
const answeredHomeInputs = new Map<string, number>();

onWritesChanged((count) => { pendingWrites.value = count; });
bridge.onStatus((status) => { hostStatus.value = status; });

/** "127.0.0.1:58741" or "my-mac.tailnet.ts.net": the Mac's address on the route in use. */
export const endpointHost = computed(() => {
  const status = hostStatus.value;
  const match = /\(([^)]+)\)\s*$/.exec(status.route);
  return match ? match[1] : status.server || "Your Mac";
});
export const isConnected = computed(() => connection.value.state === "connected");
export const homeID = computed(() => homeSummary.value?.id ?? null);
export const isHomeSelected = computed(() => selectedID.value !== null && selectedID.value === homeID.value);
/** The shown session's detail, else its listed summary while the detail loads. */
export const selectedSession = computed<Detail | RemoteSessionSummary | null>(() => {
  const id = selectedID.value;
  if (!id) return null;
  return details.value.get(id) ?? (id === homeID.value ? homeSummary.value : sessions.value.find((item) => item.id === id) ?? null);
});
export const selectedDetail = computed<Detail | null>(() => (selectedID.value ? details.value.get(selectedID.value) ?? null : null));
export const visibleHomeInputs = computed(() =>
  homeInputs.value
    .map((group) => ({ ...group, requests: group.requests.filter((request) => !answeredHomeInputs.has(request.id)) }))
    .filter((group) => group.requests.length));

export function tabTitle(session: Pick<RemoteSessionSummary, "title" | "customTitle"> | null | undefined): string {
  if (!session) return "Tab";
  const custom = session.customTitle?.trim();
  return plainMentions(custom || session.title || "Tab");
}

// MARK: Polling

let timer: ReturnType<typeof setTimeout> | null = null;
let running: Promise<void> | null = null;
let again = false;
let frontmost = bridge.focused;
let homeDataWanted = true;
let lastSuccess = 0;
let detailGeneration = 0;

export function setFrontmost(value: boolean): void {
  const wasBehind = !frontmost;
  frontmost = value;
  if (value && wasBehind) refreshNow();
  else schedule();
}

/** Home's tasks, artifacts and background refresh with each poll while Home is showing. */
export function setHomeDataWanted(value: boolean): void {
  homeDataWanted = value;
}

function busy(): boolean {
  const id = selectedID.value;
  const detail = id ? details.value.get(id) : null;
  const summary = id === homeID.value ? homeSummary.value : sessions.value.find((item) => item.id === id);
  return Boolean(detail?.isStreaming || (detail?.queuedCount ?? 0) > 0 || summary?.isStreaming || (summary?.queuedCount ?? 0) > 0)
    || detailError.value !== null || connection.value.state !== "connected";
}

function pollDelay(): number {
  const delay = busy() ? 1500 : 5000;
  return frontmost ? delay : Math.max(delay, 15000);
}

function schedule(): void {
  if (timer) clearTimeout(timer);
  timer = null;
  if (document.visibilityState === "hidden") return;
  timer = setTimeout(() => void refresh(), pollDelay());
}

document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "hidden") {
    if (timer) clearTimeout(timer);
    timer = null;
  } else refreshNow();
});

export function refreshNow(): Promise<void> {
  return refresh();
}

export function refresh(): Promise<void> {
  if (running) {
    again = true;
    return running;
  }
  running = (async () => {
    isRefreshing.value = true;
    do {
      again = false;
      await refreshOnce();
    } while (again);
  })().finally(() => {
    running = null;
    isRefreshing.value = false;
    schedule();
  });
  return running;
}

async function refreshOnce(): Promise<void> {
  let list: SessionsListResponse;
  const requestedAt = Date.now();
  try {
    list = plainList(await api<SessionsListResponse>("/api/v1/sessions"));
  } catch (error) {
    failed(error);
    return;
  }
  lastSuccess = Date.now();
  const now = Date.now();
  for (const [id, at] of answeredHomeInputs) if (now - at > 60000) answeredHomeInputs.delete(id);
  batch(() => {
    connection.value = { state: "connected", route: hostStatus.value.route, message: "" };
    errorMessage.value = null;
    sessions.value = list.sessions;
    tabSections.value = list.sections ?? [];
    supportsTabSections.value = list.supportsTabSections === true;
    homeSummary.value = list.home ?? null;
    homeInputs.value = list.homeInputs ?? [];
    listed.value = true;
    listedAt.value = requestedAt;
    // Drop details for tabs that closed (Home and the shown session stay).
    const keep = new Set([...list.sessions.map((item) => item.id), list.home?.id, selectedID.value].filter(Boolean) as string[]);
    if ([...details.value.keys()].some((id) => !keep.has(id))) {
      details.value = new Map([...details.value].filter(([id]) => keep.has(id)));
    }
  });
  const id = selectedID.value;
  if (id) {
    const summary = id === list.home?.id ? list.home : list.sessions.find((item) => item.id === id);
    const cached = details.value.get(id);
    if (!cached || !summary || cached.historyRevision !== summary.historyRevision) await fetchDetail(id, cached?.historyRevision);
  }
  if (homeDataWanted && list.home) await refreshHomeData();
}

/** Titles (a tab's can come from its first message), previews and labels read tab mentions as "@Label". */
function plainList(list: SessionsListResponse): SessionsListResponse {
  return {
    ...list,
    sessions: list.sessions.map(plainSession),
    home: list.home ? plainSession(list.home) : list.home,
    homeInputs: list.homeInputs ? plainMentionsDeep(list.homeInputs) : list.homeInputs,
  };
}

function failed(error: unknown): void {
  const message = error instanceof Error ? error.message : String(error);
  batch(() => {
    const stale = Date.now() - lastSuccess > Math.max(10000, pollDelay() + 5000);
    if (!listed.value || stale || (error instanceof APIError && error.status === 401)) {
      connection.value = { state: listed.value ? "reconnecting" : "connecting", route: hostStatus.value.route, message };
    }
    errorMessage.value = error instanceof APIError && error.status === 401
      ? "The Mac rejected this PC's pairing token. Pair again in Settings."
      : message;
  });
}

async function fetchDetail(id: string, revision?: string): Promise<void> {
  const generation = ++detailGeneration;
  try {
    const suffix = revision ? `?revision=${encodeURIComponent(revision)}` : "";
    const data = await api<SessionUpdateResponse>(`/api/v1/sessions/${pathComponent(id)}${suffix}`, { recent: true });
    if (generation !== detailGeneration && selectedID.value !== id) return;
    detailError.value = null;
    if ("session" in data) apply(data.session);
  } catch (error) {
    if (selectedID.value !== id) return;
    detailError.value = error instanceof APIError && error.status === 404
      ? "This conversation is no longer on the Mac."
      : `Couldn't update this conversation: ${(error as Error).message}`;
  }
}

/** Index of the first message of the last `groups` exchanges (as the web client and Mac do). */
function historySuffix(messages: RemoteMessage[], groups: number): RemoteMessage[] {
  const prompts = messages.flatMap((message, index) => (message.role === "user" ? [index] : []));
  return prompts.length > groups ? messages.slice(prompts[prompts.length - groups]) : messages;
}

/** Merges a session from the Mac into the cache (CantripRemoteModel.apply, CantripRemote.swift:4146). */
export function apply(received: Detail, options: { keepOlder?: boolean } = {}): void {
  const session = plainSession(received);
  const cached = details.value.get(session.id);
  let next: Detail = session;
  if (cached && session.historyStartID && cached.historyStartID === session.historyStartID) {
    const overlap = cached.messages.findIndex((message) => message.id === session.messages[0]?.id);
    if (overlap > 0) next = { ...session, messages: [...cached.messages.slice(0, overlap), ...session.messages], hasOlderMessages: cached.hasOlderMessages };
  } else if (cached && cached.historyStartID !== session.historyStartID) {
    expanded.delete(session.id);
    setHistory(session.id, null);
  }
  if (!expanded.has(session.id) && !options.keepOlder) {
    const bounded = historySuffix(next.messages, 3);
    if (bounded.length < next.messages.length) next = { ...next, messages: bounded, hasOlderMessages: true };
    if (!next.messages.some((message) => message.role === "user") && next.messages.length > 120) {
      next = { ...next, messages: next.messages.slice(-120), hasOlderMessages: true };
    }
  }
  const map = new Map(details.value);
  map.delete(session.id);
  map.set(session.id, next);
  const pinned = new Set([selectedID.value, homeID.value]);
  for (const key of map.keys()) {
    if (map.size <= 6) break;
    if (!pinned.has(key)) map.delete(key);
  }
  batch(() => {
    details.value = map;
    // Keep the listed summary in step with the detail.
    if (sessions.value.some((item) => item.id === session.id)) {
      sessions.value = sessions.value.map((item) => (item.id === session.id ? summaryOf(session, item) : item));
    } else if (homeSummary.value?.id === session.id) {
      homeSummary.value = summaryOf(session, homeSummary.value);
    }
  });
}

function summaryOf(session: Detail, previous: RemoteSessionSummary): RemoteSessionSummary {
  const { messages: _messages, queued: _queued, historyStartID: _start, hasOlderMessages: _older, threadReplies: _replies, ...summary } = session;
  return { ...previous, ...summary };
}

function setHistory(id: string, value: { loading: boolean; error: string | null } | null): void {
  const map = new Map(historyState.value);
  if (value) map.set(id, value);
  else map.delete(id);
  historyState.value = map;
}

/** Loads the page of messages before the oldest one shown (GET …?before=). */
export async function loadOlder(id: string, automatically = false): Promise<boolean> {
  const current = details.value.get(id);
  const state = historyState.value.get(id);
  const before = current?.messages[0]?.id;
  if (!current?.hasOlderMessages || !before || state?.loading || (automatically && state?.error)) return false;
  setHistory(id, { loading: true, error: null });
  try {
    const data = await api<SessionResponse>(`/api/v1/sessions/${pathComponent(id)}?before=${encodeURIComponent(before)}`);
    const latest = details.value.get(id);
    if (!latest || latest.historyStartID !== data.session.historyStartID || latest.messages[0]?.id !== before) {
      setHistory(id, null);
      return false;
    }
    const known = new Set(latest.messages.map((message) => message.id));
    const received = data.session.messages.filter((message) => !known.has(message.id));
    if (!received.length && data.session.hasOlderMessages !== false) throw new Error("The Mac sent an empty page.");
    expanded.add(id);
    const map = new Map(details.value);
    map.set(id, { ...latest, messages: [...received, ...latest.messages], hasOlderMessages: data.session.hasOlderMessages === true });
    details.value = map;
    setHistory(id, null);
    return true;
  } catch (error) {
    setHistory(id, { loading: false, error: `Couldn't load older messages: ${(error as Error).message}` });
    return false;
  }
}

/** Shows a session: its cached transcript at once, then a fresh copy from the Mac. */
export function select(id: string | null): void {
  if (selectedID.value === id) return;
  batch(() => {
    selectedID.value = id;
    detailError.value = null;
  });
  if (id) void fetchDetail(id).then(() => schedule());
}

// MARK: Home data

let tasksRevision: string | null = null;
let artifactsRevision: string | null = null;

export async function refreshHomeData(): Promise<void> {
  await Promise.all([refreshTasks(), refreshArtifacts()]);
  const home = details.value.get(homeID.value ?? "") ?? homeSummary.value;
  if ((home?.backgroundInputCount ?? 0) > 0 || homeBackground.value?.runs.some(needsInput)) await refreshBackground();
}

export async function refreshTasks(): Promise<void> {
  try {
    const query = tasksRevision && homeTasks.value ? `?revision=${encodeURIComponent(tasksRevision)}` : "";
    const data = await api<HomeTasksResponse>(`/api/v1/home/tasks${query}`);
    homeTasksError.value = null;
    if ("tasks" in data) {
      tasksRevision = data.revision;
      homeTasks.value = data;
    }
  } catch (error) {
    homeTasksError.value = `Couldn't load tasks: ${(error as Error).message}`;
  }
}

export async function refreshArtifacts(): Promise<void> {
  try {
    const query = artifactsRevision && homeArtifacts.value ? `?revision=${encodeURIComponent(artifactsRevision)}` : "";
    const data = await api<HomeArtifactsResponse>(`/api/v1/home/artifacts${query}`);
    homeArtifactsError.value = null;
    if ("artifacts" in data) {
      artifactsRevision = data.revision;
      homeArtifacts.value = data;
    }
  } catch (error) {
    homeArtifactsError.value = `Couldn't load artifacts: ${(error as Error).message}`;
  }
}

export async function refreshBackground(): Promise<void> {
  try {
    homeBackground.value = plainMentionsDeep(await api<HomeBackgroundSnapshot>("/api/v1/home/background"));
    homeBackgroundError.value = null;
  } catch (error) {
    homeBackgroundError.value = `Couldn't load background runs: ${(error as Error).message}`;
  }
}

export function needsInput(run: HomeBackgroundSnapshot["runs"][number]): boolean {
  return run.status === "running" && ((run.inputs ?? []).length > 0 || run.activity === "Needs your input");
}

// MARK: Mutations (one at a time, never retried: a lost reply may still have reached the Mac)

export async function mutate<T>(work: () => Promise<T>): Promise<T> {
  while (isMutating.value) await new Promise((resolve) => setTimeout(resolve, 50));
  isMutating.value = true;
  try {
    return await work();
  } finally {
    isMutating.value = false;
  }
}

function sessionPath(id: string, action = ""): string {
  return `/api/v1/sessions/${pathComponent(id)}${action ? `/${action}` : ""}`;
}

async function sessionAction(id: string, action: string, body?: unknown): Promise<Detail> {
  const data = await api<SessionResponse>(sessionPath(id, action), { method: "POST", body, recent: true });
  apply(data.session);
  return data.session;
}

export async function sendMessage(id: string, body: SendMessageRequest): Promise<Detail> {
  return mutate(() => sessionAction(id, "messages", body)).finally(() => schedule());
}

export async function stop(id: string): Promise<void> {
  stoppingID.value = id;
  try {
    await mutate(() => sessionAction(id, "cancel"));
  } finally {
    if (stoppingID.value === id) stoppingID.value = null;
    schedule();
  }
}

export async function resume(id: string): Promise<void> {
  await mutate(() => sessionAction(id, "resume"));
}

export async function startFresh(id: string): Promise<void> {
  await mutate(() => sessionAction(id, "start-fresh", {}));
}

/** Closes a tab; returns the tab the Mac selects instead. */
export async function closeTab(id: string): Promise<Detail> {
  const replacement = await mutate(() => sessionAction(id, "close"));
  await refresh();
  return replacement;
}

export async function createTab(): Promise<Detail> {
  const data = await mutate(() => api<SessionResponse>("/api/v1/sessions", { method: "POST", recent: true }));
  apply(data.session);
  if (!sessions.value.some((item) => item.id === data.session.id)) sessions.value = [...sessions.value, plainSession(data.session)];
  void refresh();
  return data.session;
}

export async function updateTab(id: string, change: { customTitle?: string; isLocked?: boolean }): Promise<void> {
  await mutate(() => sessionAction(id, "metadata", change));
}

/** Reorders optimistically, then applies the Mac's order (or reverts). */
export async function moveTab(id: string, targetID: string, after: boolean): Promise<void> {
  const before = sessions.value;
  const moving = before.find((item) => item.id === id);
  if (!moving || id === targetID) return;
  const rest = before.filter((item) => item.id !== id);
  const index = rest.findIndex((item) => item.id === targetID);
  if (index < 0) return;
  rest.splice(after ? index + 1 : index, 0, moving);
  sessions.value = rest;
  try {
    const data = await mutate(() => api<MoveTabResponse>(sessionPath(id, "move"), {
      method: "POST", body: { targetID, placement: after ? "after" : "before" },
    }));
    sessions.value = data.sessions.map(plainSession);
    if (data.sections) tabSections.value = data.sections;
  } catch (error) {
    sessions.value = before;
    throw error;
  }
}

function requireSections(): void {
  if (!supportsTabSections.value) throw new Error("Update and reopen Cantrip on your Mac to group its tabs into sections.");
}

/** Adds a section and, with `fileTabID`, files that tab in it. */
export async function createSection(name: string, fileTabID?: string): Promise<void> {
  requireSections();
  const data = await mutate(() => api<TabSectionsResponse>("/api/v1/sections", { method: "POST", body: { name } }));
  tabSections.value = data.sections;
  if (fileTabID && data.section) await fileTab(fileTabID, data.section.id);
  else await refresh();
}

export async function renameSection(id: string, name: string): Promise<void> {
  requireSections();
  const data = await mutate(() => api<TabSectionsResponse>(`/api/v1/sections/${encodeURIComponent(id)}`, { method: "PATCH", body: { name } }));
  tabSections.value = data.sections;
}

/** Moves a section up (-1) or down (1). */
export async function moveSection(id: string, offset: number): Promise<void> {
  const index = tabSections.value.findIndex((section) => section.id === id);
  if (index < 0) return;
  await moveSectionTo(id, index + offset);
}

/** Moves a section to `position`. The new order shows while the Mac saves it and reverts if it fails. */
export async function moveSectionTo(id: string, position: number): Promise<void> {
  requireSections();
  const before = tabSections.value;
  const moved = movedSections(before, id, position);
  if (moved === before) return;
  tabSections.value = moved;
  try {
    const data = await mutate(() => api<TabSectionsResponse>(`/api/v1/sections/${encodeURIComponent(id)}`, {
      method: "PATCH", body: { position },
    }));
    tabSections.value = data.sections;
  } catch (error) {
    if (tabSections.value === moved) tabSections.value = before;
    throw error;
  }
}

/** Deletes a section; its tabs go back to Tabs. */
export async function deleteSection(id: string): Promise<void> {
  requireSections();
  const data = await mutate(() => api<TabSectionsResponse>(`/api/v1/sections/${encodeURIComponent(id)}`, { method: "DELETE" }));
  tabSections.value = data.sections;
  await refresh();
}

/** Files a tab under a section (null: Tabs); the Mac puts it after the section's last tab. */
export async function fileTab(id: string, sectionID: string | null): Promise<void> {
  requireSections();
  await mutate(() => sessionAction(id, "metadata", { sectionID }));
  sessions.value = sessions.value.map((item) => (item.id === id ? { ...item, sectionID: sectionID ?? undefined } : item));
  await refresh();
}

/** A new tab filed under a section. */
export async function createTabInSection(sectionID: string): Promise<Detail> {
  requireSections();
  const data = await mutate(() => api<SessionResponse>("/api/v1/sessions", { method: "POST", body: { sectionID }, recent: true }));
  apply(data.session);
  if (!sessions.value.some((item) => item.id === data.session.id)) sessions.value = [...sessions.value, plainSession(data.session)];
  void refresh();
  return data.session;
}

export async function answerInput(sessionID: string, requestID: string, body: InputAnswerRequest): Promise<void> {
  try {
    await mutate(() => api(sessionPath(sessionID, `input/${pathComponent(requestID)}`), { method: "POST", body }));
    if (homeInputs.value.some((group) => group.requests.some((request) => request.id === requestID))) {
      answeredHomeInputs.set(requestID, Date.now());
      homeInputs.value = [...homeInputs.value];
    }
  } finally {
    void refresh();
  }
}

export async function cancelSubagent(sessionID: string, agentID: string): Promise<SubagentCancelResponse> {
  try {
    return await api<SubagentCancelResponse>(sessionPath(sessionID, `subagents/${pathComponent(agentID)}/cancel`), { method: "POST" });
  } finally {
    void refresh();
  }
}

export async function removeQueued(sessionID: string, promptID: string): Promise<void> {
  await mutate(async () => {
    const data = await api<SessionResponse>(sessionPath(sessionID, `queue/${pathComponent(promptID)}`), { method: "DELETE", recent: true });
    apply(data.session);
  });
}

export async function sendQueuedNow(sessionID: string, promptID: string): Promise<void> {
  await mutate(() => sessionAction(sessionID, `queue/${pathComponent(promptID)}/send`, {}));
}

/**
 * Runs a queued message in a child tab: its own tab right after the parent (and, in a git
 * repository, its own branch) that merges back when done. The parent stays open. Returns the
 * child's ID.
 */
export async function forkQueued(sessionID: string, promptID: string): Promise<string> {
  const data = await mutate(async () => {
    const response = await api<ForkQueuedResponse>(sessionPath(sessionID, `queue/${pathComponent(promptID)}/fork`), {
      method: "POST", body: {}, recent: true,
    });
    apply(response.session);
    return response;
  });
  await refresh();
  return data.childID;
}

/** One of a child tab card's `actions`, run in its parent. `open` brings back a finished child's tab. */
export async function childAction(parentID: string, childID: string, action: ChildTabAction): Promise<void> {
  await mutate(() => sessionAction(parentID, `children/${pathComponent(childID)}/${pathComponent(action)}`, {}));
  await refresh();
}

export async function stopBackgroundRun(runID: string): Promise<void> {
  homeBackground.value = plainMentionsDeep(await api<HomeBackgroundSnapshot>(`/api/v1/home/background/${pathComponent(runID)}/stop`, { method: "POST" }));
  void refresh();
}

/** Forgets cached state when the app pairs with a different Mac. */
export function reset(): void {
  batch(() => {
    sessions.value = [];
    tabSections.value = [];
    supportsTabSections.value = false;
    homeSummary.value = null;
    homeInputs.value = [];
    details.value = new Map();
    selectedID.value = null;
    homeTasks.value = null;
    homeArtifacts.value = null;
    homeBackground.value = null;
    listed.value = false;
  });
  expanded.clear();
  resetThreads();
  tasksRevision = null;
  artifactsRevision = null;
}
