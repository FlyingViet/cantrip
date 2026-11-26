import { afterEach, describe, expect, it, vi } from "vitest";

// The remote state module touches the page and the preload bridge when it loads.
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

import { clearRevalidatedReads } from "../src/gateway/api/client";
import { mergedReasoning, reasoningSteps } from "../src/gateway/state/remote";

const fetchMock = vi.fn();
vi.stubGlobal("fetch", fetchMock);

const full = [
  { title: "Checking the build", text: "The log has two warnings.", number: 1 },
  { title: "Reading the tests", text: "Three cases cover paging.", number: 2 },
];

function answer(body: unknown) {
  return Promise.resolve({ ok: true, status: 200, headers: new Headers(), text: async () => JSON.stringify(body) });
}

afterEach(() => {
  fetchMock.mockReset();
  clearRevalidatedReads();
});

describe("reasoning loaded when it's opened (reasoning=summary)", () => {
  it("asks every read for titles only and loads one reply's text from its reasoning route, once", async () => {
    fetchMock.mockImplementation(() => answer({ reasoning: full, reasoningBytes: 4096 }));
    expect(await reasoningSteps("tab-1", "msg-1", false)).toEqual(full);
    const url = String(fetchMock.mock.calls[0][0]);
    expect(url).toContain("/api/v1/sessions/tab-1/messages/msg-1/reasoning?");
    expect(url).toContain("reasoning=summary");
    expect(await reasoningSteps("tab-1", "msg-1", false)).toEqual(full);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    // A reply still being written is read again: its reasoning grows.
    await reasoningSteps("tab-1", "msg-1", true);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("puts loaded text under the titles it covers and keeps titles that arrived since", () => {
    const titles = [
      { title: "Checking the build", text: "", number: 1 },
      { title: "Reading the tests", text: "", number: 2 },
      { title: "Writing the answer", text: "", number: 3 },
    ];
    expect(mergedReasoning(titles, null)).toEqual(titles);
    expect(mergedReasoning(titles, full)).toEqual([...full, titles[2]]);
    expect(mergedReasoning(titles.slice(0, 1), full)).toEqual(full);
  });
});
