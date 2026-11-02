import { beforeEach, describe, expect, it, vi } from "vitest";

// The state and transcript modules touch the page and the preload bridge when they load. A hidden page never
// schedules polls, so only the calls made here reach `fetch`.
vi.hoisted(() => {
  const noop = () => {};
  const scope = globalThis as Record<string, unknown>;
  const stored = new Map<string, string>();
  Object.defineProperty(scope, "localStorage", {
    configurable: true,
    value: { getItem: (key: string) => stored.get(key) ?? null, setItem: (key: string, value: string) => void stored.set(key, value), removeItem: (key: string) => void stored.delete(key) },
  });
  scope.document = { addEventListener: noop, removeEventListener: noop, visibilityState: "hidden" };
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
vi.mock("../src/gateway/ui/kit", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../src/gateway/ui/kit")>()),
  confirmDialog: vi.fn(),
  toast: vi.fn(),
}));

import { APIError } from "../src/gateway/api/client";
import type { PagedRemoteSessionDetail, RemoteMessage, RemoteSessionSummary, RemoteThread } from "../src/gateway/api/types";
import {
  canDeleteMessage, DELETE_MESSAGE_CONFIRMATION, DELETE_MESSAGE_LABEL, deletedSet, isDeleted, withoutDeleted,
} from "../src/gateway/state/deleteMessage";
import * as remote from "../src/gateway/state/remote";
import { dropDeletedMessages, loadThread, openThread, showThread, threadLoad } from "../src/gateway/state/threads";
import { confirmDialog, toast } from "../src/gateway/ui/kit";
import { confirmDeleteMessage, MessageRow, messageMenu } from "../src/gateway/ui/transcript/Message";

// MARK: Fixtures (fake IDs and text)

const TAB = "5B1D7C0E-2F4A-4C61-9E0B-6A3D8F1C2B40";
const OTHER_TAB = "9C2E4A61-7B3D-4E58-8F10-2D6B0A9C3E71";
const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const [P1, A1, P2, A2, P3, A3, P4, A4] = [1, 2, 3, 4, 5, 6, 7, 8].map(id);

function message(messageID: string, role: RemoteMessage["role"], text = "Sample text"): RemoteMessage {
  return { id: messageID, role, text, thinking: "", activities: [], isLocalPrivate: false };
}

const exchange = (prompt: string, reply: string, label: string) => [message(prompt, "user", `Ask ${label}`), message(reply, "assistant", `Answer ${label}`)];
const ALL = [...exchange(P1, A1, "one"), ...exchange(P2, A2, "two"), ...exchange(P3, A3, "three"), ...exchange(P4, A4, "four")];

function detail(overrides: Partial<PagedRemoteSessionDetail> = {}): PagedRemoteSessionDetail {
  return {
    id: TAB, title: "Sample tab", customTitle: "", isLocked: false, isLocalPrivate: false, isCantripHome: false, isCantripHomeBackground: false,
    workdir: "/Users/example/project", isStreaming: false, canResume: false, councilMode: false, queuedCount: 0, pendingInputCount: 0,
    pendingInputs: [], modelSettingsRevision: "m1", historyRevision: "r1", supportsPrivateLocalSettings: false, supportsInputRequests: true,
    supportsChatInputReplies: true, supportsTabMetadata: true, supportsTabReordering: true, supportsModelSettings: true,
    supportsImageAttachments: true, supportsVideoAttachments: true, supportsFileAttachments: true, supportsMixedAttachments: true,
    supportsAutoDelivery: true, supportsQueueRemoval: true, supportsQueueSendNow: true, supportsPagedHistory: true, supportsStartFresh: true,
    supportsDeleteMessage: true, messages: [], queued: [], historyStartID: P1, hasOlderMessages: false,
    ...overrides,
  };
}

const fetchMock = vi.fn();
vi.stubGlobal("fetch", fetchMock);

function answer(status: number, body: unknown) {
  return Promise.resolve({ ok: status >= 200 && status < 300, status, text: async () => JSON.stringify(body) });
}

function call(index = 0): { url: string; init: RequestInit } {
  const [url, init] = fetchMock.mock.calls[index] as [string, RequestInit];
  return { url, init };
}

const ids = (sessionID = TAB) => remote.details.value.get(sessionID)?.messages.map((item) => item.id);

beforeEach(() => {
  remote.reset();
  fetchMock.mockReset();
  vi.mocked(confirmDialog).mockReset();
  vi.mocked(toast).mockReset();
});

// MARK: Tests

describe("who offers Delete Message", () => {
  const session = detail();

  it("offers it on prompts, replies and errors when the Mac supports it and the tab is idle", () => {
    for (const role of ["user", "assistant", "error"]) expect(canDeleteMessage(session, message(P1, role))).toBe(true);
  });

  it("never on fresh-start dividers or handoff and child cards", () => {
    expect(canDeleteMessage(session, message(P1, "freshStart"))).toBe(false);
    expect(canDeleteMessage(session, message(P1, "handoff"))).toBe(false);
    expect(canDeleteMessage(session, { ...message(P1, "handoff"), handoffResult: { id: "h", state: "done" } as never })).toBe(false);
    expect(canDeleteMessage(session, { ...message(P1, "assistant"), childResult: { childID: TAB } as never })).toBe(false);
  });

  it("not while the tab works, nor on Macs without it", () => {
    expect(canDeleteMessage(detail({ isStreaming: true }), message(P1, "user"))).toBe(false);
    expect(canDeleteMessage(detail({ supportsDeleteMessage: false }), message(P1, "user"))).toBe(false);
    expect(canDeleteMessage(detail({ supportsDeleteMessage: undefined }), message(P1, "assistant"))).toBe(false);
  });

  it("puts the confirmed, destructive action in the message menu and on the row", () => {
    const entries = messageMenu(session, P2);
    expect(entries).toHaveLength(1);
    expect(entries[0]).toMatchObject({ label: DELETE_MESSAGE_LABEL, destructive: true, disabled: false });
    expect(DELETE_MESSAGE_LABEL).toBe("Delete Message…");

    interface VNode { type: unknown; props: Record<string, unknown> & { children?: unknown } }
    const isVNode = (value: unknown): value is VNode => typeof value === "object" && value !== null && "type" in value && "props" in value;
    const vnodes = (value: unknown): VNode[] => Array.isArray(value) ? value.flatMap(vnodes) : isVNode(value) ? [value, ...vnodes(value.props.children)] : [];
    const row = (value: RemoteMessage, inSession: RemoteSessionSummary = session) =>
      MessageRow({ message: value, session: inSession, lane: "tab", streaming: false, reported: new Set() }) as unknown as VNode;
    const menus = (node: VNode) => vnodes(node).filter((item) => (item.type as { name?: string }).name === "MessageMenuButton");

    for (const role of ["user", "assistant", "error"]) {
      const node = row(message(P1, role));
      expect(menus(node)).toHaveLength(1);
      expect(typeof node.props.onContextMenu).toBe("function");
    }
    const streaming = row(message(P1, "user"), detail({ isStreaming: true }));
    expect(menus(streaming)).toHaveLength(0);
    expect(streaming.props.onContextMenu).toBeUndefined();
    expect(menus(row(message(P1, "freshStart")))).toHaveLength(0);
  });
});

describe("deleted message IDs", () => {
  it("match case-insensitively and leave untouched lists alone", () => {
    const deleted = deletedSet([P2.toLowerCase()]);
    expect(isDeleted(P2.toUpperCase(), deleted)).toBe(true);
    expect(withoutDeleted(ALL, deleted).map((item) => item.id)).toEqual([P1, A1, A2, P3, A3, P4, A4]);
    expect(withoutDeleted(ALL, deletedSet(undefined))).toBe(ALL);
    expect(withoutDeleted(ALL, deletedSet([id(99)]))).toBe(ALL);
  });

  it("drop from the cached older pages when a later copy of the session lists them", () => {
    remote.apply(detail({ messages: ALL }), { keepOlder: true });
    remote.apply(detail({ messages: ALL.slice(4), historyRevision: "r2", deletedMessageIDs: [P2, A2], hasOlderMessages: true }));
    expect(ids()).toEqual([P1, A1, P3, A3, P4, A4]);
  });

  it("drop from another tab's cached transcript when the tab list lists them (deleted on another device)", async () => {
    remote.apply(detail({ id: OTHER_TAB, messages: ALL.slice(0, 4), historyStartID: P1 }));
    fetchMock.mockImplementation((url: string) => answer(200, url.startsWith("/api/v1/sessions?")
      ? { sessions: [detail({ id: OTHER_TAB, historyRevision: "r9", deletedMessageIDs: [P1, A1] })], uiRevision: "u1" }
      : { error: "unexpected" }));
    await remote.refreshNow();
    expect(ids(OTHER_TAB)).toEqual([P2, A2]);
  });

  it("are left out of an older page", async () => {
    remote.apply(detail({ messages: ALL.slice(4), hasOlderMessages: true, deletedMessageIDs: [P2, A2] }));
    fetchMock.mockImplementation(() => answer(200, { session: detail({ messages: ALL.slice(0, 4), hasOlderMessages: false, deletedMessageIDs: [P2, A2] }) }));
    expect(await remote.loadOlder(TAB)).toBe(true);
    expect(call().url).toContain(`before=${P3}`);
    expect(ids()).toEqual([P1, A1, P3, A3, P4, A4]);
  });

  it("drop from fetched threads, and a deleted prompt's thread is forgotten and closed", async () => {
    const thread: RemoteThread = {
      id: P1, prompt: { id: P1, text: "Ask one" }, hasEarlier: false,
      messages: [{ id: A1, role: "assistant", text: "Answer one" }, { id: A2, role: "assistant", text: "Answer two" }],
    };
    fetchMock.mockImplementation(() => answer(200, { thread }));
    showThread({ sessionID: TAB, threadID: P1, prompt: "Ask one", messageID: null });
    await loadThread(TAB, P1);
    expect(threadLoad(P1)?.state).toBe("loaded");

    dropDeletedMessages(deletedSet([A2]));
    const load = threadLoad(P1);
    expect(load?.state === "loaded" ? load.thread.messages.map((item) => item.id) : null).toEqual([A1]);
    expect(openThread.value?.threadID).toBe(P1);

    dropDeletedMessages(deletedSet([P1, A1]));
    expect(threadLoad(P1)).toBeUndefined();
    expect(openThread.value).toBeNull();
  });
});

describe("POST …/delete-message", () => {
  it("sends the message ID with the session-action query and applies the returned session", async () => {
    remote.apply(detail({ messages: ALL }), { keepOlder: true });
    const after = detail({ messages: [...ALL.slice(0, 2), ...ALL.slice(4)], historyRevision: "r2", deletedMessageIDs: [P2, A2] });
    fetchMock.mockImplementation(() => answer(200, { session: after }));

    await remote.deleteMessage(TAB, A2);

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const { url, init } = call();
    expect(url).toBe(`/api/v1/sessions/${TAB}/delete-message?history=recent&recentExchanges=3`);
    expect(init.method).toBe("POST");
    expect(JSON.parse(String(init.body))).toEqual({ messageID: A2 });
    expect((init.headers as Record<string, string>)["content-type"]).toBe("application/json");
    expect(ids()).toEqual([P1, A1, P3, A3, P4, A4]);
    expect(remote.isMutating.value).toBe(false);
  });

  it("drops the deleted message from older cached pages even when the Mac's list leaves it out", async () => {
    remote.apply(detail({ messages: ALL }), { keepOlder: true });
    fetchMock.mockImplementation(() => answer(200, { session: detail({ messages: ALL.slice(6), historyRevision: "r2", hasOlderMessages: true }) }));
    await remote.deleteMessage(TAB, A3);
    expect(ids()).toEqual([P2, A2, P3, P4, A4]);
  });

  it("rejects with the Mac's error text", async () => {
    const text = "Wait for this tab to finish before deleting a message.";
    fetchMock.mockImplementation(() => answer(409, { error: text }));
    const failure = await remote.deleteMessage(TAB, P1).then(() => null, (error: unknown) => error);
    expect(failure).toBeInstanceOf(APIError);
    expect((failure as APIError).message).toBe(text);
    expect((failure as APIError).status).toBe(409);
    expect(remote.isMutating.value).toBe(false);
  });
});

describe("confirming", () => {
  it("asks with the shared wording and sends nothing on Cancel", async () => {
    vi.mocked(confirmDialog).mockResolvedValue(false);
    expect(await confirmDeleteMessage(TAB, P1)).toBe(false);
    expect(confirmDialog).toHaveBeenCalledWith(DELETE_MESSAGE_CONFIRMATION);
    expect(DELETE_MESSAGE_CONFIRMATION).toEqual({
      title: "Delete this message?",
      message: "This removes the message and its reply from this tab's history on the Mac, and the model won't have them anymore. This can't be undone.",
      confirm: "Delete", cancel: "Cancel", destructive: true,
    });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("deletes on Delete, and shows a failure's text", async () => {
    vi.mocked(confirmDialog).mockResolvedValue(true);
    remote.apply(detail({ messages: ALL.slice(0, 4) }));
    fetchMock.mockImplementationOnce(() => answer(200, { session: detail({ messages: ALL.slice(2, 4), historyRevision: "r2", deletedMessageIDs: [P1, A1] }) }));
    expect(await confirmDeleteMessage(TAB, P1)).toBe(true);
    expect(ids()).toEqual([P2, A2]);
    expect(toast).not.toHaveBeenCalled();

    fetchMock.mockImplementationOnce(() => answer(404, { error: "That message is no longer in this conversation." }));
    expect(await confirmDeleteMessage(TAB, P2)).toBe(false);
    expect(toast).toHaveBeenCalledWith("Delete Message failed: That message is no longer in this conversation.");
  });
});
