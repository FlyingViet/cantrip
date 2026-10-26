import { beforeEach, describe, expect, it, vi } from "vitest";

// The transcript modules touch the page and the preload bridge when they load.
vi.hoisted(() => {
  const noop = () => {};
  const scope = globalThis as Record<string, unknown>;
  const stored = new Map<string, string>();
  Object.defineProperty(scope, "localStorage", {
    configurable: true,
    value: { getItem: (key: string) => stored.get(key) ?? null, setItem: (key: string, value: string) => void stored.set(key, value), removeItem: (key: string) => void stored.delete(key) },
  });
  scope.document = { addEventListener: noop, removeEventListener: noop, visibilityState: "visible" };
  scope.window = scope;
  scope.addEventListener = noop;
  scope.removeEventListener = noop;
});
vi.mock("../src/gateway/bridge", () => ({
  bridge: {
    key: "gateway-key", version: "test", platform: "win32", server: "", focused: true,
    status: { connected: true, route: "", message: "", server: "" },
    openSettings() {}, openExternal() {}, showLog() {}, onStatus() {}, onCommand() {}, onActive() {},
  },
  isWindows: true,
  primaryKeyLabel: "Ctrl+",
  shortcut: (keys: string) => keys,
}));

import { threadPath } from "../src/gateway/api/client";
import type { RemoteMessage, RemoteSessionSummary, RemoteThread, RemoteThreadTag } from "../src/gateway/api/types";
import {
  closeThread, loadThread, openThread, repliesLabel, resetThreads, showThread, speaker, tagLabel, threadLines, threadLoad, threadReplies, threadTag,
  type ThreadLine,
} from "../src/gateway/state/threads";
import { mascotName } from "../src/gateway/ui/pip/prefs";
import { MessageRow } from "../src/gateway/ui/transcript/Message";
import { ThreadBody, ThreadLaneRow, ThreadQuote, ThreadRepliesButton } from "../src/gateway/ui/transcript/ThreadTags";

// MARK: A small VNode walker (no DOM): components are called with their props, like a shallow render.

interface VNode { type: unknown; props: Record<string, unknown> & { children?: unknown } }
interface Element { tag: string; props: Record<string, unknown>; children: Node[] }
type Node = Element | string;

function isVNode(value: unknown): value is VNode {
  return typeof value === "object" && value !== null && "type" in value && "props" in value;
}

/** Renders components without hooks all the way down to elements and text. */
function render(value: unknown): Node[] {
  if (value == null || typeof value === "boolean") return [];
  if (Array.isArray(value)) return value.flatMap(render);
  if (typeof value === "string" || typeof value === "number") return [String(value)];
  if (!isVNode(value)) return [];
  if (typeof value.type === "function") return render((value.type as (props: unknown) => unknown)(value.props));
  const { children, ...props } = value.props;
  return [{ tag: String(value.type), props, children: render(children) }];
}

function text(nodes: Node[]): string {
  return nodes.map((node) => (typeof node === "string" ? node : text(node.children))).join("");
}

function elements(nodes: Node[]): Element[] {
  return nodes.flatMap((node) => (typeof node === "string" ? [] : [node, ...elements(node.children)]));
}

function byClass(nodes: Node[], name: string): Element[] {
  return elements(nodes).filter((node) => String(node.props.class ?? "").split(" ").includes(name));
}

/** Every VNode in a tree, in order, without calling components (for rows whose parts use hooks). */
function vnodes(value: unknown): VNode[] {
  if (Array.isArray(value)) return value.flatMap(vnodes);
  if (!isVNode(value)) return [];
  return [value, ...vnodes(value.props.children)];
}

const named = (node: VNode, name: string) => (node.type as { name?: string }).name === name;

// MARK: Fixtures

const SESSION = "7EAE0CE5-8C8B-4652-9FD0-214867A90E5D";
const PROMPT_ID = "0D5FFAC1-8184-49D0-B59F-17B469E281C9";
const TAGGED = "019F13D4-DDB2-4044-8655-2C0C2298EEC7";
const TAG: RemoteThreadTag = { id: PROMPT_ID, prompt: "does it make sense to be able to tag a tab either from cantrip home or a main tab…" };
const THREAD: RemoteThread = {
  id: PROMPT_ID,
  prompt: { id: PROMPT_ID, text: "does it make sense to be able to tag a tab either from cantrip home or a main tab to ask the child tab questions?" },
  messages: [
    { id: "A1", role: "assistant", text: "Let me **check** first.\n\nThen hand it off." },
    { id: "U1", role: "user", text: "Hand the on-demand version to the Cantrip tab (Recommended)" },
    { id: "H1", role: "handoff", text: "Stopped in Cantrip" },
    { id: TAGGED, role: "error", text: "The tab stopped." },
  ],
  hasEarlier: true,
};

function message(overrides: Partial<RemoteMessage>): RemoteMessage {
  return { id: TAGGED, role: "assistant", text: "Done.", thinking: "", activities: [], isLocalPrivate: false, ...overrides };
}

const session = { id: SESSION, title: "Cantrip Home", threadReplies: { [PROMPT_ID]: 4, other: 0 } } as unknown as RemoteSessionSummary;
const row = (value: RemoteMessage, inSession = session) => MessageRow({ message: value, session: inSession, lane: "home", streaming: false, reported: new Set() });
const lined = (value: RemoteMessage, threadLine: ThreadLine) =>
  MessageRow({ message: value, session, lane: "home", streaming: false, reported: new Set(), threadLine }) as unknown as VNode;

const fetchMock = vi.fn();
vi.stubGlobal("fetch", fetchMock);

function answer(status: number, body: unknown) {
  return Promise.resolve({ ok: status >= 200 && status < 300, status, text: async () => JSON.stringify(body) });
}

function quote(children?: unknown): Node[] {
  return render(ThreadQuote({ sessionID: SESSION, messageID: TAGGED, tag: TAG, children: children as never }));
}

function body(): Node[] {
  const focus = openThread.value!;
  return render(ThreadBody({ focus, load: threadLoad(focus.threadID), assistantName: "Pip" }));
}

/** Lets fetches that have answered finish (without asking for the thread again, which would refresh it). */
async function settle(): Promise<void> {
  for (let i = 0; i < 6; i++) await new Promise((resolve) => setTimeout(resolve, 0));
}

function click(node: Element): void {
  (node.props.onClick as () => void)();
}

beforeEach(() => {
  resetThreads();
  fetchMock.mockReset();
  mascotName.value = "";
});

describe("thread tags", () => {
  it("quotes the prompt only where the Mac sent a tag, above the lane badge, never on prompts", () => {
    expect(threadTag(message({ thread: TAG }))).toEqual(TAG);
    expect(threadTag(message({ role: "handoff", thread: TAG }))).toEqual(TAG);
    expect(threadTag(message({ role: "error", thread: TAG }))).toEqual(TAG);
    expect(threadTag(message({ role: "user", thread: TAG }))).toBeNull();
    expect(threadTag(message({ threadID: PROMPT_ID }))).toBeNull();

    const tagged = vnodes(row(message({ threadID: PROMPT_ID, thread: TAG })));
    const head = tagged.find((node) => node.type === ThreadQuote)!;
    expect(head.props).toMatchObject({ sessionID: SESSION, messageID: TAGGED, tag: TAG });
    expect(named(head.props.children as VNode, "LaneBadge")).toBe(true);
    expect(tagged.filter((node) => named(node, "LaneBadge"))).toHaveLength(1);

    const plain = vnodes(row(message({ threadID: PROMPT_ID })));
    expect(plain.some((node) => node.type === ThreadQuote)).toBe(false);
    expect(plain.some((node) => named(node, "LaneBadge"))).toBe(true);
    expect(vnodes(row(message({ role: "user", thread: TAG }))).some((node) => node.type === ThreadQuote)).toBe(false);
  });

  it("puts a handoff result card's quote above the card, without a lane badge", () => {
    const card = message({
      role: "handoff", thread: TAG,
      handoffResult: { delegationID: "D", tabID: "T", tabTitle: "Cantrip", state: "cancelled", summary: "On-demand insight", detail: "" } as RemoteMessage["handoffResult"],
    });
    const nodes = vnodes(row(card));
    const head = nodes.findIndex((node) => node.type === ThreadQuote);
    const result = nodes.findIndex((node) => named(node, "HandoffResultCard"));
    expect(head).toBeGreaterThan(0);
    expect(result).toBeGreaterThan(head);
    expect(nodes.some((node) => named(node, "LaneBadge"))).toBe(false);
  });

  it("lets the rows after a quote that stay in its thread share its line, turning into the last reply", () => {
    const book: RemoteThreadTag = { id: "A", prompt: "Process the book" };
    const run = [
      message({ id: "q", text: "Chapters 3 and 4", threadID: "A", thread: book }),
      message({ id: "r", threadID: "A" }),
      message({ id: "s", role: "handoff", threadID: "A" }),
      message({ id: "p", role: "user", threadID: "p" }),
      message({ id: "t", threadID: "p" }),
    ];
    expect(Object.fromEntries(threadLines(run))).toEqual({ q: "start", r: "through", s: "end" });
    expect(threadLines([run[0], run[3], run[4]]).size).toBe(0);
    const answered = [
      message({ id: "q", text: "Which?", threadID: "A", thread: book }),
      message({ id: "u", role: "user", text: "This one", threadID: "A" }),
      message({ id: "e", text: " ", threadID: "B" }),
      message({ id: "r", text: "On it", threadID: "A" }),
      message({ id: "v", role: "user", text: "Thanks", threadID: "A" }),
    ];
    // Answers and empty replies stay in a run, but it ends on a reply.
    expect(Object.fromEntries(threadLines(answered))).toEqual({ q: "start", u: "through", e: "through", r: "end" });
    const broken = [
      message({ id: "q", threadID: "A", thread: book }),
      message({ id: "f", role: "freshStart", text: "Started fresh" }),
      message({ id: "r", threadID: "A" }),
      message({ id: "x", threadID: "A", thread: book }),
      message({ id: "y", threadID: "A" }),
      message({ id: "z", threadID: "C", thread: { id: "C", prompt: "Other" } }),
      message({ id: "w", role: "error", text: "Failed", threadID: "C" }),
    ];
    expect(Object.fromEntries(threadLines(broken))).toEqual({ x: "start", y: "end", z: "start", w: "end" });

    // The first row's line runs on past the badge, beside the rest of the reply.
    const first = lined(message({ threadID: PROMPT_ID, thread: TAG }), "start");
    expect(first.props.class).toBe("turn assistant thread-start");
    const firstNodes = vnodes(first);
    expect(firstNodes.find((node) => node.type === ThreadQuote)!.props.continues).toBe(true);
    const rest = firstNodes.find((node) => node.props.class === "thread-rest")!;
    expect(vnodes(rest.props.children).some((node) => named(node, "ReplyText"))).toBe(true);
    expect(byClass(render(ThreadLaneRow({ continues: true, children: "badge" })), "continues")).toHaveLength(1);
    // Rows it passes carry it; the last reply's badge row turns it in, with no quote.
    expect(lined(message({ id: "u", role: "user", threadID: PROMPT_ID }), "through").props.class).toBe("turn user thread-through");
    const last = lined(message({ threadID: PROMPT_ID }), "end");
    expect(last.props.class).toBe("turn assistant thread-end");
    const lastNodes = vnodes(last);
    const laneRow = lastNodes.find((node) => node.type === ThreadLaneRow)!;
    expect(laneRow.props.continues).toBeUndefined();
    expect(named(laneRow.props.children as VNode, "LaneBadge")).toBe(true);
    expect(lastNodes.some((node) => node.type === ThreadQuote || node.props.class === "thread-rest")).toBe(false);
  });

  it("draws the quote as a button named after the prompt, with the thread line around it", () => {
    const nodes = quote();
    const button = elements(nodes).find((node) => node.tag === "button")!;
    expect(button.props).toMatchObject({ type: "button", class: "thread-quote", "aria-label": `Reply to: ${TAG.prompt}. Opens the thread` });
    expect(tagLabel(TAG)).toBe(`Reply to: ${TAG.prompt}`);
    expect(text([button])).toBe(TAG.prompt);
    expect(byClass(nodes, "thread-arm")[0].props["aria-hidden"]).toBe("true");
    expect(byClass(nodes, "thread-lane-row")).toHaveLength(1);
    // Cards have no lane badge: the line turns into a spacer instead.
    expect(byClass(nodes, "thread-spacer")).toHaveLength(1);
    expect(byClass(quote("badge"), "thread-spacer")).toHaveLength(0);
  });

  it("says N Replies under a prompt whose thread was split up", () => {
    expect(threadReplies(session, PROMPT_ID)).toBe(4);
    expect(threadReplies(session, "other")).toBeNull();
    expect(threadReplies({ id: SESSION } as RemoteSessionSummary, PROMPT_ID)).toBeNull();
    expect(repliesLabel(1)).toBe("1 Reply");
    expect(repliesLabel(4)).toBe("4 Replies");

    const prompt = vnodes(row(message({ id: PROMPT_ID, role: "user", text: "does it make sense…", threadID: PROMPT_ID })));
    const replies = prompt.find((node) => node.type === ThreadRepliesButton)!;
    expect(replies.props).toMatchObject({ sessionID: SESSION, promptID: PROMPT_ID, prompt: "does it make sense…", count: 4 });
    expect(vnodes(row(message({ id: "other", role: "user", text: "Hi" }))).some((node) => node.type === ThreadRepliesButton)).toBe(false);

    const button = render(ThreadRepliesButton({ sessionID: SESSION, promptID: PROMPT_ID, prompt: "does it make sense…", count: 4 }))[0] as Element;
    expect(button.props["aria-label"]).toBe("4 Replies. Opens the thread");
    expect(text([button])).toBe("4 Replies");
    fetchMock.mockImplementation(() => answer(200, { thread: THREAD }));
    click(button);
    expect(openThread.value).toEqual({ sessionID: SESSION, threadID: PROMPT_ID, prompt: "does it make sense…", messageID: null });
  });

  it("opens the whole thread from the quote, fetched from the Mac", async () => {
    let release!: () => void;
    fetchMock.mockImplementation(() => new Promise((resolve) => { release = () => resolve(answer(200, { thread: THREAD })); }));
    click(elements(quote()).find((node) => node.tag === "button")!);
    expect(openThread.value).toEqual({ sessionID: SESSION, threadID: PROMPT_ID, prompt: TAG.prompt, messageID: TAGGED });
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe(`/api/v1/sessions/${SESSION}/threads/${PROMPT_ID}?history=recent`);
    expect(init.method).toBe("GET");
    expect(init.headers["x-cantrip-gateway"]).toBe("gateway-key");
    const loading = body();
    expect(byClass(loading, "thread-mine").map((node) => text([node]))).toEqual([TAG.prompt]);
    expect(text(loading)).toContain("Loading the thread…");

    release();
    await settle();
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const open = body();
    expect(byClass(open, "thread-mine").map((node) => text([node]))).toEqual([THREAD.prompt.text, "Hand the on-demand version to the Cantrip tab (Recommended)"]);
    expect(text(open)).toContain("Earlier messages in this thread aren't shown.");
    expect(byClass(open, "child-who").map((node) => text([node]))).toEqual(["Pip", "Handoff", "Error"]);
    // Whole replies, as Messages shows a thread: every paragraph, with its formatting.
    const first = byClass(open, "thread-bubble")[0];
    expect(elements([first]).some((node) => node.tag === "strong" && text([node]) === "check")).toBe(true);
    expect(text([first])).toContain("Then hand it off.");
    // The reply it was opened from can be scrolled to.
    expect(elements(open).some((node) => node.props["data-message-id"] === TAGGED)).toBe(true);
  });

  it("fetches again when the conversation changes, and a failed refresh keeps the thread", async () => {
    let release!: () => void;
    fetchMock.mockImplementation(() => new Promise((resolve) => { release = () => resolve(answer(200, { thread: THREAD })); }));
    showThread({ sessionID: SESSION, threadID: PROMPT_ID, prompt: TAG.prompt, messageID: null });
    // A change while the fetch is on its way: one more fetch once it lands.
    void loadThread(SESSION, PROMPT_ID);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    release();
    await settle();
    expect(fetchMock).toHaveBeenCalledTimes(2);
    release();
    await settle();
    expect(threadLoad(PROMPT_ID)?.state).toBe("loaded");

    fetchMock.mockImplementationOnce(() => answer(500, { error: "busy" }));
    await loadThread(SESSION, PROMPT_ID);
    expect(fetchMock).toHaveBeenCalledTimes(3);
    expect(threadLoad(PROMPT_ID)?.state).toBe("loaded");
    expect(byClass(body(), "thread-mine")).toHaveLength(2);
    closeThread();
    expect(openThread.value).toBeNull();
  });

  it("shows why a thread couldn't load, and Try again fetches it again", async () => {
    fetchMock.mockImplementationOnce(() => answer(404, { error: "This thread's first message is no longer available." }));
    showThread({ sessionID: SESSION, threadID: PROMPT_ID, prompt: TAG.prompt, messageID: TAGGED });
    await settle();
    const failed = body();
    const alert = elements(failed).find((node) => node.props.role === "alert")!;
    expect(text([alert])).toBe("Couldn't load this thread: This thread's first message is no longer available.");
    const retry = elements(failed).find((node) => node.tag === "button" && text([node]) === "Try again")!;

    fetchMock.mockImplementationOnce(() => answer(200, { thread: THREAD }));
    click(retry);
    await settle();
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(byClass(body(), "thread-mine")[0].children).toEqual([THREAD.prompt.text]);
  });

  it("labels Home's replies with Pip's chosen name and the Council author", () => {
    expect(speaker({ id: "a", role: "assistant", text: "" }, "Nova")).toBe("Nova");
    expect(speaker({ id: "a", role: "assistant", text: "", author: "GPT-5" }, "Pip")).toBe("Pip · GPT-5");
    expect(speaker({ id: "h", role: "handoff", text: "" }, "Pip")).toBe("Handoff");
    expect(speaker({ id: "e", role: "error", text: "" }, "Pip")).toBe("Error");
  });

  it("encodes the thread path and drops replies that arrive after a reset", async () => {
    expect(threadPath("a b", "c/d")).toBe("/api/v1/sessions/a%20b/threads/c%2Fd");
    expect(threadPath("a b", "c/d", "e&f")).toBe("/api/v1/sessions/a%20b/threads/c%2Fd?before=e%26f");
    let release!: () => void;
    fetchMock.mockImplementation(() => new Promise((resolve) => { release = () => resolve(answer(200, { thread: THREAD })); }));
    showThread({ sessionID: SESSION, threadID: PROMPT_ID, prompt: TAG.prompt, messageID: null });
    resetThreads();
    release();
    await settle();
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(threadLoad(PROMPT_ID)).toBeUndefined();
    expect(openThread.value).toBeNull();
  });
});
