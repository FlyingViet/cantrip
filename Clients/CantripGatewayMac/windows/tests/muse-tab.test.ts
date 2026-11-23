import { beforeEach, describe, expect, it, vi } from "vitest";

// The sheet touches the page and the preload bridge when it loads. A hidden page never schedules polls, so only
// the calls made here reach `fetch`.
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

import type { RemoteSessionSummary } from "../src/gateway/api/types";
import { startFreshSupport } from "../src/gateway/state/format";
import { startFreshEntry, tabActions } from "../src/gateway/ui/tabActions";

// Fake IDs and text only.
const MUSE = {
  id: "6D7A1E5C-0B3F-4C1E-9A3B-5E0C4D2F1A77", title: "Muse", customTitle: "", isLocked: true, isMuse: true,
  isLocalPrivate: false, isCantripHome: false, isCantripHomeBackground: false, supportsTabMetadata: true,
  supportsModelSettings: false, supportsStartFresh: false,
} as unknown as RemoteSessionSummary;
const TAB = { ...MUSE, id: "3F6B2A10-8C4D-4E7F-9A1B-5D0C7E2F4A86", title: "Sample tab", isLocked: false, isMuse: undefined,
  supportsModelSettings: true } as unknown as RemoteSessionSummary;

function labels(session: RemoteSessionSummary): string[] {
  return tabActions(session).map((entry) => ("label" in entry ? entry.label : "-"));
}

function entry(session: RemoteSessionSummary, label: string) {
  return tabActions(session).find((item) => "label" in item && item.label === label) as { disabled?: boolean } | undefined;
}

describe("the Muse tab's menu", () => {
  it("has no model, Start Fresh or tools, can't be unlocked or closed, and says what it is", () => {
    const shown = labels(MUSE);
    for (const hidden of ["Model Settings", "Start Fresh", "MCP Servers", "Skills & Rules"]) expect(shown).not.toContain(hidden);
    expect(entry(MUSE, "Unlock Tab")?.disabled).toBe(true);
    expect(entry(MUSE, "Close Tab")?.disabled).toBe(true);
    expect(shown.some((label) => label.startsWith("Your Muse chat."))).toBe(true);
  });

  it("leaves other tabs as they were", () => {
    const shown = labels(TAB);
    expect(shown).toContain("Model Settings");
    expect(shown).toContain("MCP Servers");
    expect(entry(TAB, "Lock Tab")?.disabled).toBe(false);
    expect(entry(TAB, "Close Tab")?.disabled).toBe(false);
    expect(shown.some((label) => label.startsWith("Your Muse chat."))).toBe(false);
  });
});

describe("Start Fresh for Cantrip Home's chat", () => {
  const HOME = { ...TAB, id: "7EAE0CE5-0000-4000-8000-000000000001", title: "Cantrip Home", isCantripHome: true,
    isLocked: true, isStreaming: false, queuedCount: 0 } as unknown as RemoteSessionSummary;

  it("is offered when the Mac supports it, and hidden on Macs before", () => {
    const current = { ...HOME, supportsStartFresh: true } as RemoteSessionSummary;
    expect(startFreshSupport(current)).toBe(true);
    const entries = startFreshEntry(current);
    expect(entries.map((item) => ("label" in item ? item.label : "-"))).toEqual(["Start Fresh"]);
    expect((entries[0] as { disabled?: boolean }).disabled).toBe(false);
    expect(startFreshSupport({ ...HOME, supportsStartFresh: false } as RemoteSessionSummary)).toBe(false);
    expect(startFreshSupport({ ...HOME, supportsStartFresh: undefined } as unknown as RemoteSessionSummary)).toBe(false);
    expect(startFreshEntry({ ...HOME, supportsStartFresh: false } as RemoteSessionSummary)).toEqual([]);
  });

  it("waits while Home works", () => {
    const busy = { ...HOME, supportsStartFresh: true, isStreaming: true } as RemoteSessionSummary;
    expect((startFreshEntry(busy)[0] as { disabled?: boolean }).disabled).toBe(true);
  });
});
