import { beforeEach, describe, expect, it, vi } from "vitest";

// The state modules touch the page and the preload bridge when they load. A hidden page never schedules polls.
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

import type { PagedRemoteSessionDetail, RemoteMessage, RemoteSubagent } from "../src/gateway/api/types";
import { settleBackgroundAgents } from "../src/gateway/state/backgroundAgents";
import * as remote from "../src/gateway/state/remote";
import { liveBackgroundSubagents } from "../src/gateway/ui/activity/activityLogic";

// MARK: Fixtures (fake IDs and text)

const TAB = "5B1D7C0E-2F4A-4C61-9E0B-6A3D8F1C2B40";
const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const [P1, A1, P2, A2, P3, A3] = [1, 2, 3, 4, 5, 6].map(id);

function agent(agentID: string, overrides: Partial<RemoteSubagent> = {}): RemoteSubagent {
  return {
    id: `call_${agentID}`, agentID, name: `watch-${agentID}`, agentType: "task", summary: "", background: true,
    status: "running", startedAt: 1_790_000_000, steps: 1, tokens: 10, canCancel: true, recentSteps: [], ...overrides,
  } as RemoteSubagent;
}

function message(messageID: string, role: RemoteMessage["role"], subagents?: RemoteSubagent[]): RemoteMessage {
  return { id: messageID, role, text: "Sample text", thinking: "", activities: [], isLocalPrivate: false, ...(subagents ? { subagents } : {}) };
}

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

beforeEach(() => remote.reset());

// MARK: Tests

describe("background agents the Mac no longer runs", () => {
  it("settle only listed-as-finished background agents, keeping the same array when nothing changes", () => {
    const watch = agent("build");
    const side = agent("side", { status: "idle" });
    const foreground = agent("explore", { background: false });
    const messages = [message(A1, "assistant", [watch, side, foreground])];
    const settled = settleBackgroundAgents(messages, [side.id]);
    expect(settled[0].subagents?.map((item) => [item.status, item.canCancel])).toEqual([["completed", false], ["idle", true], ["running", true]]);
    expect(settleBackgroundAgents(messages, undefined)).toBe(messages);
    expect(settleBackgroundAgents(messages, [watch.id, side.id])).toBe(messages);
  });

  it("settle a watcher cached in a reply that left the Mac's recent window", () => {
    const watch = agent("build");
    remote.apply(detail({
      messages: [message(P1, "user"), message(A1, "assistant", [watch]), message(P2, "user"), message(A2, "assistant")],
      backgroundTaskIDs: [watch.id],
    }));
    expect(liveBackgroundSubagents(remote.details.value.get(TAB)?.messages).map((item) => item.id)).toEqual([watch.id]);

    remote.apply(detail({
      historyRevision: "r2", backgroundTaskIDs: [],
      messages: [message(P2, "user"), message(A2, "assistant"), message(P3, "user"), message(A3, "assistant")],
    }));
    const messages = remote.details.value.get(TAB)?.messages ?? [];
    expect(messages.map((item) => item.id)).toEqual([P1, A1, P2, A2, P3, A3]);
    expect(messages[1].subagents?.[0]).toMatchObject({ status: "completed", canCancel: false });
    expect(liveBackgroundSubagents(messages)).toEqual([]);
  });

  it("keep what older Macs said when they send no list", () => {
    const watch = agent("build");
    remote.apply(detail({ messages: [message(P1, "user"), message(A1, "assistant", [watch])] }));
    expect(liveBackgroundSubagents(remote.details.value.get(TAB)?.messages).map((item) => item.id)).toEqual([watch.id]);
  });
});
