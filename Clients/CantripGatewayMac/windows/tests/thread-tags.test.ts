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
import { loadThread, panelID, resetThreads, speaker, tagLabel, threadTag, threadView, toggleThread } from "../src/gateway/state/threads";
import { mascotName } from "../src/gateway/ui/pip/prefs";
import { MessageRow } from "../src/gateway/ui/transcript/Message";
import { ThreadPanel, ThreadTagButton } from "../src/gateway/ui/transcript/ThreadTags";

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
    { id: "E1", role: "error", text: "The tab stopped." },
  ],
  hasEarlier: true,
};

function message(overrides: Partial<RemoteMessage>): RemoteMessage {
  return { id: TAGGED, role: "assistant", text: "Done.", thinking: "", activities: [], isLocalPrivate: false, ...overrides };
}

const session = { id: SESSION, title: "Cantrip Home" } as RemoteSessionSummary;
const row = (value: RemoteMessage) => MessageRow({ message: value, session, lane: "home", streaming: false, reported: new Set() });

const fetchMock = vi.fn();
vi.stubGlobal("fetch", fetchMock);

function answer(status: number, body: unknown) {
  return Promise.resolve({ ok: status >= 200 && status < 300, status, text: async () => JSON.stringify(body) });
}

function tagButton(id = TAGGED): Element {
  return render(ThreadTagButton({ sessionID: SESSION, messageID: id, tag: TAG }))[0] as Element;
}

function panel(id = TAGGED): Node[] {
  return render(ThreadPanel({ sessionID: SESSION, messageID: id, tag: TAG }));
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
  it("shows a tag only where the Mac sent one, and never on prompts", () => {
    expect(threadTag(message({ thread: TAG }))).toEqual(TAG);
    expect(threadTag(message({ role: "handoff", thread: TAG }))).toEqual(TAG);
    expect(threadTag(message({ role: "error", thread: TAG }))).toEqual(TAG);
    expect(threadTag(message({ role: "user", thread: TAG }))).toBeNull();
    expect(threadTag(message({ threadID: PROMPT_ID }))).toBeNull();

    const tagged = vnodes(row(message({ threadID: PROMPT_ID, thread: TAG })));
    const lane = tagged.find((node) => node.props.class === "lane-row")!;
    const parts = vnodes(lane.props.children).filter((node) => node !== lane);
    expect(parts).toHaveLength(2);
    expect((parts[0].type as { name: string }).name).toBe("LaneBadge");
    expect(parts[1].type).toBe(ThreadTagButton);
    expect(parts[1].props).toMatchObject({ sessionID: SESSION, messageID: TAGGED, tag: TAG });
    expect(tagged.some((node) => node.type === ThreadPanel)).toBe(true);

    expect(vnodes(row(message({ threadID: PROMPT_ID }))).some((node) => node.type === ThreadTagButton)).toBe(false);
    expect(vnodes(row(message({ role: "user", thread: TAG }))).some((node) => node.type === ThreadTagButton)).toBe(false);
  });

  it("puts a handoff result card's tag above the card", () => {
    const card = message({
      role: "handoff", thread: TAG,
      handoffResult: { delegationID: "D", tabID: "T", tabTitle: "Cantrip", state: "cancelled", summary: "On-demand insight", detail: "" } as RemoteMessage["handoffResult"],
    });
    const nodes = vnodes(row(card));
    const tag = nodes.findIndex((node) => node.type === ThreadTagButton);
    const result = nodes.findIndex((node) => (node.type as { name?: string }).name === "HandoffResultCard");
    expect(tag).toBeGreaterThan(0);
    expect(result).toBeGreaterThan(tag);
    expect(nodes.some((node) => (node.type as { name?: string }).name === "LaneBadge")).toBe(false);
  });

  it("is a button named after the prompt that controls its panel", () => {
    const button = tagButton();
    expect(button.tag).toBe("button");
    expect(button.props).toMatchObject({
      type: "button", class: "thread-tag", "aria-expanded": "false", "aria-controls": panelID(TAGGED), "aria-label": `Reply to: ${TAG.prompt}`,
    });
    expect(tagLabel(TAG)).toBe(`Reply to: ${TAG.prompt}`);
    expect(text([button])).toBe(TAG.prompt);
    expect(byClass([button], "truncate")).toHaveLength(1);
    expect(byClass([button], "thread-chevron")[0].props.class).not.toContain("flipped");

    const closed = panel()[0] as Element;
    expect(closed.props).toMatchObject({ id: panelID(TAGGED), hidden: true });
    expect(closed.children).toEqual([]);
  });

  it("fetches the thread from the Mac on first open and shows it", async () => {
    let release!: () => void;
    fetchMock.mockImplementation(() => new Promise((resolve) => { release = () => resolve(answer(200, { thread: THREAD })); }));
    click(tagButton());
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe(`/api/v1/sessions/${SESSION}/threads/${PROMPT_ID}?before=${TAGGED}&history=recent`);
    expect(init.method).toBe("GET");
    expect(init.headers["x-cantrip-gateway"]).toBe("gateway-key");
    expect(tagButton().props["aria-expanded"]).toBe("true");
    expect(byClass([tagButton()], "thread-chevron")[0].props.class).toContain("flipped");
    expect(text(panel())).toBe("Loading the thread…");

    release();
    await loadThread(SESSION, TAGGED, PROMPT_ID);
    const open = panel();
    expect((open[0] as Element).props.hidden).toBe(false);
    expect(byClass(open, "child-prompt").map((node) => text([node]))).toEqual([THREAD.prompt.text, "Hand the on-demand version to the Cantrip tab (Recommended)"]);
    expect(text(open)).toContain("Earlier messages in this thread aren't shown.");
    expect(byClass(open, "child-who").map((node) => text([node]))).toEqual(["Pip", "Handoff", "Error"]);
    const first = byClass(open, "child-reply")[0];
    expect(elements([first]).some((node) => node.tag === "strong" && text([node]) === "check")).toBe(true);
    // A blank line between paragraphs would waste one of the 3 lines.
    expect(elements([first]).filter((node) => node.tag === "br")).toHaveLength(1);
  });

  it("keeps a thread open and fetched across re-renders, closing and reopening", async () => {
    fetchMock.mockImplementation(() => answer(200, { thread: { ...THREAD, hasEarlier: false } }));
    toggleThread(SESSION, TAGGED, TAG);
    await Promise.all([loadThread(SESSION, TAGGED, PROMPT_ID), loadThread(SESSION, TAGGED, PROMPT_ID)]);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    // A row rendered again from scratch (new page of history, switching back to Home) is still open.
    expect(tagButton().props["aria-expanded"]).toBe("true");
    expect(text(panel())).not.toContain("Earlier messages");
    expect(threadView("another-message").open).toBe(false);

    click(tagButton());
    expect(tagButton().props["aria-expanded"]).toBe("false");
    expect((panel()[0] as Element).props.hidden).toBe(true);
    click(tagButton());
    await loadThread(SESSION, TAGGED, PROMPT_ID);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(byClass(panel(), "child-prompt")).toHaveLength(2);
  });

  it("shows why a thread couldn't load, and Try again fetches it again", async () => {
    fetchMock.mockImplementationOnce(() => answer(404, { error: "This thread's first message is no longer available." }));
    toggleThread(SESSION, TAGGED, TAG);
    await loadThread(SESSION, TAGGED, PROMPT_ID);
    const failed = panel();
    const alert = elements(failed).find((node) => node.props.role === "alert")!;
    expect(text([alert])).toBe("Couldn't load this thread: This thread's first message is no longer available.");
    const retry = elements(failed).find((node) => node.tag === "button" && text([node]) === "Try again")!;

    fetchMock.mockImplementationOnce(() => answer(200, { thread: THREAD }));
    click(retry);
    await loadThread(SESSION, TAGGED, PROMPT_ID);
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(byClass(panel(), "child-prompt")[0].children).toEqual([THREAD.prompt.text]);
  });

  it("labels Home's replies with Pip's chosen name and the Council author", async () => {
    fetchMock.mockImplementation(() => answer(200, { thread: THREAD }));
    toggleThread(SESSION, TAGGED, TAG);
    await loadThread(SESSION, TAGGED, PROMPT_ID);
    mascotName.value = "Nova";
    expect(text([byClass(panel(), "child-who")[0]])).toBe("Nova");
    expect(speaker({ id: "a", role: "assistant", text: "" }, "Nova")).toBe("Nova");
    expect(speaker({ id: "a", role: "assistant", text: "", author: "GPT-5" }, "Pip")).toBe("Pip · GPT-5");
    expect(speaker({ id: "h", role: "handoff", text: "" }, "Pip")).toBe("Handoff");
    expect(speaker({ id: "e", role: "error", text: "" }, "Pip")).toBe("Error");
  });

  it("encodes the thread path and drops replies that arrive after a reset", async () => {
    expect(threadPath("a b", "c/d", "e&f")).toBe("/api/v1/sessions/a%20b/threads/c%2Fd?before=e%26f");
    let release!: () => void;
    fetchMock.mockImplementation(() => new Promise((resolve) => { release = () => resolve(answer(200, { thread: THREAD })); }));
    toggleThread(SESSION, TAGGED, TAG);
    const pending = loadThread(SESSION, TAGGED, PROMPT_ID);
    resetThreads();
    release();
    await pending;
    expect(threadView(TAGGED)).toEqual({ open: false });
  });
});
