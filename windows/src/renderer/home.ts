// The Cantrip Home window (read-only): Home's recent conversation, its Background runs with their
// Full Log, and Tasks with their workspaces, as the paired Mac serves them. Mac strings go into
// textContent; only Home's replies are Markdown, sanitized with DOMPurify. Cards use cards.ts.
import DOMPurify from "dompurify";
import { marked } from "marked";
import "./home.css";
import { cardElement } from "./cards";
import {
  appleDate,
  buildDetail,
  buildQueueNote,
  buildExtra,
  pipelineLabel,
  pipelineSteps,
  cardsOf,
  hasRecordCards,
  listedBuilds,
  listedTabTasks,
  tabTaskDetail,
  recordDetails,
  recordTitle,
  statusLabel,
  statusTone,
} from "../shared/home";
import type {
  HomeBackgroundRun,
  HomeBackgroundSnapshot,
  HomeBuild,
  HomeMessage,
  HomeRead,
  HomeSession,
  HomeStatus,
  HomeTask,
  HomeTaskRecord,
  HomeTasksSnapshot,
} from "../shared/home";
import type { CardDocument } from "../shared/cards";

type View = "home" | "background" | "tasks";
type Detail =
  | { kind: "log" }
  | { kind: "workspace"; taskID: string }
  | { kind: "record"; taskID: string; recordID: string };

interface RecordCards {
  key: string;
  cards: CardDocument[];
  dueAt: number;
}

const POLL_MS = 15_000;
const api = window.cantripHome;

const pairView = byId<HTMLElement>("pair-view");
const pairForm = byId<HTMLFormElement>("pair-form");
const pairLink = byId<HTMLTextAreaElement>("pair-link");
const pairSubmit = byId<HTMLButtonElement>("pair-submit");
const pairError = byId<HTMLElement>("pair-error");
const app = byId<HTMLElement>("home-app");
const connection = byId<HTMLElement>("home-connection");
const content = byId<HTMLElement>("home-content");
const statusLine = byId<HTMLElement>("home-status");
const refreshButton = byId<HTMLButtonElement>("home-refresh");
const unpairButton = byId<HTMLButtonElement>("home-unpair");
const navButtons = [...document.querySelectorAll<HTMLButtonElement>(".home-nav button[data-view]")];

const state: {
  status: HomeStatus | null;
  view: View;
  detail: Detail | null;
  home: HomeSession | null;
  background: HomeBackgroundSnapshot | null;
  log: HomeSession | null;
  tasks: HomeTasksSnapshot | null;
  record: RecordCards | null;
  error: string;
  loading: boolean;
  updatedAt: Date | null;
} = {
  status: null,
  view: "home",
  detail: null,
  home: null,
  background: null,
  log: null,
  tasks: null,
  record: null,
  error: "",
  loading: false,
  updatedAt: null,
};

let renderedSignature = "";
/** The view and detail last drawn, so a refresh of the same one keeps its scroll position. */
let renderedPlace = "";
let refreshTicket = 0;

function byId<T extends HTMLElement>(id: string): T {
  const element = document.getElementById(id);
  if (!element) throw new Error(`Missing #${id}`);
  return element as T;
}

function el<K extends keyof HTMLElementTagNameMap>(tag: K, className?: string, text?: string): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function button(label: string, key: string, onClick: () => void, className = "secondary-button"): HTMLButtonElement {
  const node = el("button", className, label);
  node.type = "button";
  node.dataset.key = key;
  node.addEventListener("click", onClick);
  return node;
}

const dateFormat = new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
const timeFormat = new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" });

function when(seconds: number | undefined): string {
  const date = appleDate(seconds);
  return date ? dateFormat.format(date) : "";
}

function openExternal(url: string): void {
  void api.openExternal(url);
}

function cardStack(cards: unknown, label: string): HTMLElement | null {
  const nodes = cardsOf(cards)
    .map((card) => cardElement(card, openExternal))
    .filter((node): node is HTMLElement => Boolean(node));
  if (!nodes.length) return null;
  const stack = el("div", "home-cards");
  stack.setAttribute("role", "group");
  stack.setAttribute("aria-label", label);
  stack.append(...nodes);
  return stack;
}

function badge(status: string): HTMLElement {
  return el("span", `home-badge tone-${statusTone(status)}`, statusLabel(status));
}

function heading(text: string, level: "h2" | "h3" = "h2"): HTMLElement {
  const node = el(level, level === "h2" ? "view-title" : undefined, text);
  if (level === "h2") node.id = "view-title";
  return node;
}

function backButton(label: string, onClick: () => void): HTMLButtonElement {
  const node = button(`‹ ${label}`, `back:${label}`, onClick, "back-button");
  node.setAttribute("aria-label", `Back to ${label}`);
  return node;
}

function note(text: string, className = "view-note"): HTMLElement {
  return el("p", className, text);
}

function markdown(text: string): HTMLElement {
  const body = el("div", "message-body markdown");
  const html = marked.parse(text, { async: false, breaks: true, gfm: true }) as string;
  body.innerHTML = DOMPurify.sanitize(html, { USE_PROFILES: { html: true } });
  return body;
}

// MARK: - Conversation (Home and the Full Log)

function messageItem(message: HomeMessage): HTMLElement | null {
  const item = el("li", `message role-${message.role}`);
  if (message.role === "freshStart") {
    item.append(el("p", "message-divider", "Started fresh"));
    return item;
  }
  const result = message.handoffResult;
  const author =
    message.role === "user" ? "You"
      : message.role === "handoff" ? `${result?.kind === "ask" ? "Question" : "Handoff"} · ${result?.tabTitle || "tab"}`
        : message.role === "error" ? "Error"
          : "Cantrip Home";
  item.append(el("h3", "message-author", author));
  const text = (message.displayText ?? message.text ?? "").trim();
  if (message.role === "handoff" && result) {
    const body = el("div", "message-body plain");
    body.append(el("p", "message-summary", result.summary));
    if (result.detail) body.append(el("p", undefined, result.detail));
    item.append(body);
  } else if (message.role === "assistant" && text) {
    item.append(markdown(text));
  } else if (text) {
    item.append(el("div", "message-body plain", text));
  }
  const cards = cardStack(message.cards, "Cards for this reply");
  if (cards) item.append(cards);
  return item.childElementCount > 1 ? item : null;
}

function conversation(session: HomeSession | null, empty: string): HTMLElement {
  const wrap = el("div");
  if (!session) {
    wrap.append(note(state.loading ? "Loading…" : empty));
    return wrap;
  }
  if (session.hasOlderMessages) wrap.append(note("Older messages stay on the Mac.", "view-note small"));
  const list = el("ol", "messages");
  for (const message of Array.isArray(session.messages) ? session.messages : []) {
    const item = messageItem(message);
    if (item) list.append(item);
  }
  if (!list.childElementCount) wrap.append(note(empty));
  else wrap.append(list);
  return wrap;
}

function renderHome(): HTMLElement[] {
  return [
    heading("Home"),
    note("Your latest conversation with Cantrip Home. Reply from Cantrip on the Mac, your iPhone or Cantrip Gateway."),
    conversation(state.home, "No messages yet."),
  ];
}

// MARK: - Background

function runItem(run: HomeBackgroundRun): HTMLElement {
  const item = el("li", "home-item");
  const article = el("article");
  const titleID = `run-${run.id}`;
  article.setAttribute("aria-labelledby", titleID);
  const head = el("header", "item-head");
  const title = el("h3", "item-title", run.label || "Background run");
  title.id = titleID;
  head.append(title, badge(run.status));
  article.append(head);
  const meta = [
    run.status === "running" ? `Started ${when(run.startedAt)}` : run.finishedAt ? `Finished ${when(run.finishedAt)}` : when(run.startedAt),
    run.model,
  ].filter(Boolean).join(" · ");
  if (meta) article.append(el("p", "item-meta", meta));
  if (run.activity && run.status === "running") article.append(el("p", "item-activity", run.activity));
  if (run.summary?.trim()) article.append(el("p", "item-summary", run.summary.trim()));
  const cards = run.status === "running" ? null : cardStack(run.cards, `Cards from ${run.label || "this run"}`);
  if (cards) article.append(cards);
  item.append(article);
  return item;
}

/** Where a job is in its steps: a segment per step (done, the one it's on filled to its percentage
 * or sweeping, those to come) over their names. Paused or waiting on disk dims the current step. */
function pipelineNode(build: HomeBuild): HTMLElement | null {
  const pipeline = build.pipeline;
  if (!pipeline || !Array.isArray(pipeline.steps) || !pipeline.steps.length) return null;
  const known = typeof pipeline.fraction === "number";
  const stalled = build.state === "paused" || build.state === "waitingOnDisk" || build.state === "idle";
  const wrap = el("div", `job-pipe${stalled ? " stalled" : ""}`);
  wrap.setAttribute("role", "img");
  wrap.setAttribute("aria-label", pipelineLabel(pipeline));
  const bar = el("div", "job-pipe-bar");
  const names = el("div", "job-pipe-names");
  for (const step of pipelineSteps(pipeline)) {
    const segment = el("span", step.kind);
    segment.title = `${step.step}. ${step.name}`;
    if (step.kind === "now" && (known || build.state !== "paused")) {
      const fill = el("span", known ? "fill" : "fill sweep");
      if (known) fill.style.width = `${Math.min(Math.max(pipeline.fraction ?? 0, 0), 1) * 100}%`;
      segment.append(fill);
    }
    bar.append(segment);
    names.append(el("span", step.kind, step.text));
  }
  wrap.append(bar, names);
  return wrap;
}

function buildItem(build: HomeBuild, place: number): HTMLElement {
  const item = el("li", "home-item");
  item.append(el("span", "item-title", build.title));
  item.append(el("span", "item-meta", buildDetail(build, place, (date) => timeFormat.format(date))));
  const pipe = pipelineNode(build);
  if (pipe) item.append(pipe);
  const extra = buildExtra(build);
  if (extra) item.append(el("span", "item-meta mono", extra));
  return item;
}

function renderBackground(): HTMLElement[] {
  if (state.detail?.kind === "log") {
    return [
      backButton("Background", () => navigate("background", null)),
      heading("Full Log"),
      note("Every background run's full reply, as Home's background log keeps it."),
      conversation(state.log, "The log is empty."),
    ];
  }
  const snapshot = state.background;
  const head = el("div", "view-head");
  head.append(heading("Background"));
  if (snapshot?.sessionID) head.append(button("Full Log", "full-log", () => navigate("background", { kind: "log" })));
  const nodes: HTMLElement[] = [head];
  if (!snapshot) {
    nodes.push(note(state.loading ? "Loading…" : "Background runs couldn't be loaded."));
    return nodes;
  }
  const running = snapshot.runningCount ?? snapshot.runs.filter((run) => run.status === "running").length;
  nodes.push(note(running ? `${running} running` : "Nothing running right now."));
  const tabTasks = listedTabTasks(snapshot);
  if (tabTasks.length) {
    nodes.push(heading("In tabs", "h3"));
    for (const tab of tabTasks) {
      const group = el("ul", "home-list compact");
      group.setAttribute("aria-label", `${tab.tabTitle || "A tab"}: background tasks`);
      for (const task of tab.tasks) {
        const item = el("li", "home-item");
        item.append(el("span", "item-title", task.name || task.agentType || "Background task"));
        const meta = [tab.tabTitle || "A tab", tabTaskDetail(task, (date) => timeFormat.format(date))].join(" · ");
        item.append(el("span", "item-meta", meta));
        const now = (task.currentStep || task.latestMessage || task.summary || "").trim();
        if (now) item.append(el("span", "item-meta", now));
        group.append(item);
      }
      nodes.push(group);
    }
  }
  const builds = listedBuilds(snapshot);
  if (builds) {
    nodes.push(heading("Jobs", "h3"));
    const list = el("ol", "home-list compact");
    list.setAttribute("aria-label", "Jobs on your Mac");
    builds.running.forEach((build) => list.append(buildItem(build, 0)));
    builds.waiting.forEach((build, index) => list.append(buildItem(build, index + 1)));
    nodes.push(list, note(buildQueueNote(builds)));
  }
  if (snapshot.queued?.length) {
    nodes.push(heading("Waiting", "h3"));
    const queued = el("ul", "home-list compact");
    for (const job of snapshot.queued) {
      const item = el("li", "home-item");
      item.append(el("span", "item-title", job.label));
      const detail = [job.reason, job.dueAt ? `due ${when(job.dueAt)}` : ""].filter(Boolean).join(" · ");
      if (detail) item.append(el("span", "item-meta", detail));
      queued.append(item);
    }
    nodes.push(queued);
  }
  if (builds || tabTasks.length) nodes.push(heading("Scheduled and automated", "h3"));
  const runs = el("ol", "home-list");
  runs.setAttribute("aria-label", "Background runs");
  for (const run of snapshot.runs) runs.append(runItem(run));
  nodes.push(runs.childElementCount ? runs : note("No background runs yet."));
  return nodes;
}

// MARK: - Tasks

function findTask(id: string): HomeTask | undefined {
  return state.tasks?.tasks.find((task) => task.id === id);
}

function taskItem(task: HomeTask): HTMLElement {
  const item = el("li", "home-item");
  const article = el("article");
  const titleID = `task-${task.id}`;
  article.setAttribute("aria-labelledby", titleID);
  const head = el("header", "item-head");
  const title = el("h3", "item-title", task.title);
  title.id = titleID;
  head.append(title, badge(task.state));
  article.append(head);
  const schedule = task.hasSchedule === false ? "Manual" : task.schedule?.summary;
  const next = task.nextRunAt ? `next ${when(task.nextRunAt)}` : "";
  const meta = [schedule, next].filter(Boolean).join(" · ");
  if (meta) article.append(el("p", "item-meta", meta));
  const run = task.runs?.[0];
  if (run) {
    const latest = el("section", "latest-run");
    latest.setAttribute("aria-label", `Latest run of ${task.title}`);
    const line = el("p", "item-meta");
    line.append(el("span", undefined, "Latest run "), badge(run.status), el("span", undefined, ` ${when(run.finishedAt)}`));
    latest.append(line);
    if (run.summary?.trim()) latest.append(el("p", "item-summary", run.summary.trim()));
    const cards = cardStack(run.cards, `Cards from ${task.title}'s latest run`);
    if (cards) latest.append(cards);
    article.append(latest);
  }
  if (task.workspace) {
    const count = task.workspace.records.length;
    const noun = count === 1 ? task.workspace.recordLabel : (task.workspace.recordLabelPlural || `${task.workspace.recordLabel}s`);
    article.append(button(`Open workspace · ${count} ${noun.toLowerCase()}`, `workspace:${task.id}`,
      () => navigate("tasks", { kind: "workspace", taskID: task.id })));
  }
  item.append(article);
  return item;
}

function renderWorkspace(task: HomeTask): HTMLElement[] {
  const workspace = task.workspace!;
  const nodes: HTMLElement[] = [backButton("Tasks", () => navigate("tasks", null)), heading(task.title)];
  const cards = cardStack(state.tasks?.workspaceCards?.[task.id], `${task.title} cards`);
  if (cards) nodes.push(cards);
  const list = el("ul", "home-list compact");
  list.setAttribute("aria-label", workspace.recordLabelPlural || `${workspace.recordLabel}s`);
  for (const record of workspace.records) {
    const item = el("li", "home-item");
    const open = button("", `record:${record.id}`, () => navigate("tasks", { kind: "record", taskID: task.id, recordID: record.id }), "record-button");
    open.append(el("span", "item-title", recordTitle(workspace, record)));
    const subtitle = workspace.list.subtitleFields.map((key) => record.values[key]?.trim()).filter(Boolean).join(" · ");
    if (subtitle) open.append(el("span", "item-meta", subtitle));
    item.append(open);
    list.append(item);
  }
  nodes.push(list.childElementCount ? list : note(`No ${(workspace.recordLabelPlural || "records").toLowerCase()} yet.`));
  return nodes;
}

function renderRecord(task: HomeTask, record: HomeTaskRecord): HTMLElement[] {
  const workspace = task.workspace!;
  const nodes: HTMLElement[] = [
    backButton(task.title, () => navigate("tasks", { kind: "workspace", taskID: task.id })),
    heading(recordTitle(workspace, record)),
  ];
  const key = `${task.id}/${record.id}`;
  if (state.record?.key === key) {
    const cards = cardStack(state.record.cards, `${recordTitle(workspace, record)} cards`);
    if (cards) nodes.push(cards);
  }
  for (const section of recordDetails(workspace, record)) {
    const block = el("section", "record-section");
    if (section.title) block.append(heading(section.title, "h3"));
    const list = el("dl", "record-fields");
    for (const row of section.rows) list.append(el("dt", undefined, row.label), el("dd", undefined, row.value));
    block.append(list);
    nodes.push(block);
  }
  return nodes;
}

function renderTasks(): HTMLElement[] {
  const snapshot = state.tasks;
  if (!snapshot) return [heading("Tasks"), note(state.loading ? "Loading…" : "Tasks couldn't be loaded.")];
  const detail = state.detail;
  if (detail?.kind === "workspace" || detail?.kind === "record") {
    const task = findTask(detail.taskID);
    const record = detail.kind === "record" ? task?.workspace?.records.find((item) => item.id === detail.recordID) : undefined;
    if (task?.workspace && detail.kind === "workspace") return renderWorkspace(task);
    if (task?.workspace && record) return renderRecord(task, record);
    state.detail = null;
  }
  const nodes: HTMLElement[] = [heading("Tasks")];
  if (snapshot.error) nodes.push(note(snapshot.error, "view-note warning"));
  const list = el("ol", "home-list");
  list.setAttribute("aria-label", "Tasks");
  for (const task of snapshot.tasks) list.append(taskItem(task));
  nodes.push(list.childElementCount ? list : note("No tasks yet. Ask Cantrip Home to set one up."));
  return nodes;
}

// MARK: - Shell

function signature(): string {
  const data =
    state.view === "home" ? state.home
      : state.view === "background" ? (state.detail?.kind === "log" ? state.log : state.background)
        : [state.tasks, state.record];
  return JSON.stringify([state.view, state.detail, state.loading && !data, data]);
}

function render(force = false): void {
  const paired = Boolean(state.status?.paired);
  pairView.hidden = paired;
  app.hidden = !paired;
  if (!paired) return;
  connection.textContent = [state.status?.server, state.status?.route].filter(Boolean).join(" · ");
  document.title = state.status?.server ? `Cantrip Home · ${state.status.server}` : "Cantrip Home";
  for (const nav of navButtons) {
    if (nav.dataset.view === state.view) nav.setAttribute("aria-current", "page");
    else nav.removeAttribute("aria-current");
  }
  const updated = state.updatedAt ? `Updated ${timeFormat.format(state.updatedAt)}` : "";
  statusLine.textContent = state.error || (state.loading ? "Loading…" : updated);
  statusLine.classList.toggle("error", Boolean(state.error));

  const next = signature();
  if (!force && next === renderedSignature) return;
  const place = JSON.stringify([state.view, state.detail]);
  const sameView = place === renderedPlace;
  renderedSignature = next;
  renderedPlace = place;
  const focusKey = (document.activeElement as HTMLElement | null)?.dataset?.key;
  const scroll = content.scrollTop;
  const nodes = state.view === "home" ? renderHome() : state.view === "background" ? renderBackground() : renderTasks();
  content.replaceChildren(...nodes);
  content.setAttribute("aria-labelledby", "view-title");
  if (sameView) content.scrollTop = scroll;
  if (focusKey) content.querySelector<HTMLElement>(`[data-key="${CSS.escape(focusKey)}"]`)?.focus();
}

function navigate(view: View, detail: Detail | null): void {
  state.view = view;
  state.detail = detail;
  if (detail?.kind !== "record") state.record = null;
  state.error = "";
  render(true);
  content.scrollTop = 0;
  content.focus({ preventScroll: true });
  void refresh();
}

async function read(request: HomeRead): Promise<unknown | null> {
  const result = await api.read(request);
  if (result.ok) return result.data;
  state.error = result.error;
  return null;
}

async function refresh(): Promise<void> {
  if (!state.status?.paired) return;
  const ticket = ++refreshTicket;
  const view = state.view;
  const detail = state.detail;
  state.loading = true;
  state.error = "";
  render();
  try {
    if (view === "home") {
      const data = await read({ kind: "home" });
      if (ticket !== refreshTicket) return;
      if (data) state.home = (data as { session?: HomeSession }).session ?? null;
    } else if (view === "background") {
      const data = await read({ kind: "background" });
      if (ticket !== refreshTicket) return;
      if (data) state.background = data as HomeBackgroundSnapshot;
      if (detail?.kind === "log" && data) {
        const log = await read({ kind: "log" });
        if (ticket !== refreshTicket) return;
        if (log) state.log = (log as { session?: HomeSession }).session ?? null;
      }
    } else {
      const data = await read(state.tasks?.revision ? { kind: "tasks", revision: state.tasks.revision } : { kind: "tasks" });
      if (ticket !== refreshTicket) return;
      if (data && !(data as { unchanged?: boolean }).unchanged) state.tasks = data as HomeTasksSnapshot;
      if (detail?.kind === "record" && state.tasks?.supportsRecordCards && hasRecordCards(findTask(detail.taskID)?.workspace)) {
        const key = `${detail.taskID}/${detail.recordID}`;
        if (state.record?.key !== key || Date.now() >= state.record.dueAt) {
          const answer = await read({ kind: "recordCards", taskID: detail.taskID, recordID: detail.recordID });
          if (ticket !== refreshTicket) return;
          if (answer) {
            const { cards, refreshAfter } = answer as { cards?: unknown; refreshAfter?: number };
            const seconds = typeof refreshAfter === "number" && Number.isFinite(refreshAfter) ? Math.max(30, refreshAfter) : 300;
            state.record = { key, cards: cardsOf(cards), dueAt: Date.now() + seconds * 1000 };
          }
        }
      }
    }
    if (!state.error) state.updatedAt = new Date();
  } finally {
    if (ticket === refreshTicket) {
      state.loading = false;
      render();
    }
  }
}

pairForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  pairSubmit.disabled = true;
  pairError.textContent = "Checking the link with your Mac…";
  try {
    const result = await api.pair(pairLink.value);
    if (!result.ok) {
      pairError.textContent = result.error;
      return;
    }
    pairLink.value = "";
    pairError.textContent = "";
    state.status = result.status;
    state.error = result.notice ?? "";
    render(true);
    void refresh();
  } finally {
    pairSubmit.disabled = false;
  }
});

unpairButton.addEventListener("click", async () => {
  if (!window.confirm("Unpair this PC from your Mac? You can pair again with a new link from cantrip pair.")) return;
  state.status = await api.unpair();
  state.home = state.background = state.log = state.tasks = null;
  state.record = null;
  renderedSignature = "";
  render(true);
  pairLink.focus();
});

refreshButton.addEventListener("click", () => void refresh());
for (const nav of navButtons) {
  nav.addEventListener("click", () => navigate(nav.dataset.view as View, null));
}

// Links in Home's replies open in the browser; this window never navigates.
document.addEventListener("click", (event) => {
  const link = (event.target as Element | null)?.closest?.("a[href]");
  if (!link) return;
  event.preventDefault();
  const href = link.getAttribute("href") ?? "";
  if (/^https?:\/\//i.test(href)) openExternal(href);
});

window.addEventListener("focus", () => void refresh());
setInterval(() => {
  if (document.visibilityState === "visible") void refresh();
}, POLL_MS);

void (async () => {
  state.status = await api.status();
  render(true);
  if (state.status.paired) void refresh();
  else pairLink.focus();
})();
