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

import type { ModelSettingsSnapshot, RemoteSessionSummary } from "../src/gateway/api/types";
import * as remote from "../src/gateway/state/remote";
import { modelSettingsState } from "../src/gateway/ui/sheets/ModelSettingsSheet";
import {
  MAC_BACKEND, modelSettingsQuery, modelSettingsSave, tabBackendChoices, tabBackendName, tabBackendNote, tabBackendValue,
} from "../src/gateway/ui/sheets/sheetLogic";

// MARK: Fixtures (fake IDs, models and text)

const TAB = "3F6B2A10-8C4D-4E7F-9A1B-5D0C7E2F4A86";
const PATH = `/api/v1/sessions/${TAB}/model-settings`;
const SESSION = { id: TAB, title: "Sample tab", supportsModelSettings: true } as RemoteSessionSummary;

const BACKENDS: ModelSettingsSnapshot["backends"] = [
  { id: "Copilot", label: "Copilot", available: true },
  { id: "Claude Code", label: "Claude Code", available: true, note: "Signed out on the Mac" },
  { id: "Codex", label: "Codex", available: false, note: "Not installed on the Mac" },
  { id: "Antigravity", label: "Antigravity", available: true },
];

/** GET model-settings for a tab following the Mac's Copilot backend, on Mac defaults. */
const ON_MAC: ModelSettingsSnapshot = {
  backend: "Copilot", macBackend: "Copilot", backends: BACKENDS,
  selection: { model: "sample-model-a", effort: "", contextTier: "default" },
  defaults: { model: "sample-model-a", effort: "", contextTier: "default" },
  usesDefaults: true, revision: "rev-1", isRefreshing: false,
  models: [{ id: "sample-model-a", reasoningEfforts: ["low", "high"], contextTiers: ["default"] }],
};

/** `?backend=Claude%20Code`: the tab's own pick there, Claude's models, the tab's revision. */
const ON_CLAUDE: ModelSettingsSnapshot = {
  ...ON_MAC, backend: "Claude Code",
  selection: { model: "sample-claude-b", effort: "high", contextTier: "" },
  defaults: { model: "sample-claude-a", effort: "", contextTier: "" },
  usesDefaults: false,
  models: [{ id: "sample-claude-a", reasoningEfforts: ["low"] }, { id: "sample-claude-b", reasoningEfforts: ["low", "high"] }],
};

const ON_ANTIGRAVITY: ModelSettingsSnapshot = {
  ...ON_MAC, backend: "Antigravity", usesDefaults: true,
  selection: { model: "sample-gravity-a", effort: "", contextTier: "" },
  defaults: { model: "sample-gravity-a", effort: "", contextTier: "" },
  models: [{ id: "sample-gravity-a", reasoningEfforts: [] }],
};

/** A tab on its own Claude Code backend while the Mac runs one without per-tab models. */
const OWN_CLAUDE: ModelSettingsSnapshot = { ...ON_CLAUDE, ownBackend: "Claude Code", macBackend: "Sample ACP", revision: "rev-2" };
const OWN_CLAUDE_ON_MAC: ModelSettingsSnapshot = {
  ...OWN_CLAUDE, backend: "Sample ACP", models: [], usesDefaults: true,
  selection: { model: "", effort: "", contextTier: "" }, defaults: { model: "", effort: "", contextTier: "" },
  unavailableReason: "Sample ACP has no per-tab models. Choose Copilot, Claude Code, Codex or Antigravity for this tab.",
};

/** A Mac from before tab backends: no backend fields at all. */
const OLDER_MAC: ModelSettingsSnapshot = {
  selection: { model: "sample-model-a", effort: "low", contextTier: "default" },
  defaults: { model: "sample-model-a", effort: "", contextTier: "default" },
  usesDefaults: false, revision: "rev-0", isRefreshing: false,
  models: [{ id: "sample-model-a", reasoningEfforts: ["low", "high"], contextTiers: ["default"] }],
};

const fetchMock = vi.fn();
vi.stubGlobal("fetch", fetchMock);

function answer(status: number, body: unknown) {
  return Promise.resolve({ ok: status >= 200 && status < 300, status, text: async () => JSON.stringify(body) });
}

/** Answers model-settings GETs by `?backend=` (none = the tab's own) and POSTs with the tab's settings. */
function serve(tab: ModelSettingsSnapshot, previews: Record<string, ModelSettingsSnapshot>) {
  fetchMock.mockImplementation((url: string) => {
    const backend = new URL(url, "http://mac.invalid").searchParams.get("backend");
    return answer(200, backend === null ? tab : previews[backend]);
  });
}

function calls(): { url: string; method: string; body: unknown }[] {
  return fetchMock.mock.calls.map(([url, init]: [string, RequestInit]) => ({
    url, method: init.method ?? "GET", body: typeof init.body === "string" ? JSON.parse(init.body) : undefined,
  }));
}

function posted(): unknown {
  const writes = calls().filter((call) => call.method === "POST");
  expect(writes).toHaveLength(1);
  return writes[0].body;
}

/** A reply held until the test lets it through. */
function held(body: unknown): { reply: Promise<unknown>; release: () => void } {
  let release = () => {};
  const reply = new Promise<unknown>((resolve) => { release = () => resolve(answer(200, body)); });
  return { reply, release };
}

beforeEach(() => {
  remote.reset();
  fetchMock.mockReset();
});

// MARK: Picker

describe("the Backend picker", () => {
  it("is hidden on Macs before tab backends and when the tab can't choose (Cantrip Home)", () => {
    expect(tabBackendChoices(OLDER_MAC)).toBeNull();
    expect(tabBackendChoices({ ...ON_MAC, backends: [] })).toBeNull();
    expect(tabBackendChoices(null)).toBeNull();
  });

  it("lists the Mac's backend first, then each backend with its note; one not installed can't be picked", () => {
    expect(tabBackendChoices(ON_MAC)).toEqual([
      { value: "mac", label: "Mac's backend (Copilot)" },
      { value: "Copilot", label: "Copilot", disabled: false },
      { value: "Claude Code", label: "Claude Code — Signed out on the Mac", disabled: false },
      { value: "Codex", label: "Codex — Not installed on the Mac", disabled: true },
      { value: "Antigravity", label: "Antigravity", disabled: false },
    ]);
    // A backend this Mac no longer lists stays visible while picked.
    expect(tabBackendChoices(ON_MAC, "Sample CLI")?.at(-1)).toEqual({ value: "Sample CLI", label: "Sample CLI" });
  });

  it("starts on the tab's own backend, else the Mac's", () => {
    expect(tabBackendValue(ON_MAC)).toBe(MAC_BACKEND);
    expect(tabBackendValue(OWN_CLAUDE)).toBe("Claude Code");
    expect(tabBackendValue(OLDER_MAC)).toBe("mac");
  });

  it("names the backend the next message runs on", () => {
    expect(tabBackendNote(tabBackendName(ON_MAC, "Claude Code")))
      .toBe("The next message runs on Claude Code and continues this conversation with the recent history.");
    expect(tabBackendName(OWN_CLAUDE, MAC_BACKEND)).toBe("Sample ACP");
  });

  it("asks about another backend by its encoded name, with or without a model refresh", () => {
    expect(modelSettingsQuery("Claude Code", false)).toBe("?backend=Claude%20Code");
    expect(modelSettingsQuery("mac", true)).toBe("?backend=mac&refresh=true");
    expect(modelSettingsQuery(null, true)).toBe("?refresh=true");
    expect(modelSettingsQuery(null, false)).toBe("");
  });
});

// MARK: Save bodies

describe("model settings saves", () => {
  const override = { model: "sample-claude-b", effort: "high", contextTier: "" };

  it("send exactly today's body while the backend is unchanged", () => {
    expect(modelSettingsSave(ON_MAC, { backend: "mac", settings: ON_MAC, selection: null })).toEqual({ revision: "rev-1", usesDefaults: true });
    const body = modelSettingsSave(OWN_CLAUDE, { backend: "Claude Code", settings: OWN_CLAUDE, selection: override });
    expect(body).toEqual({ revision: "rev-2", usesDefaults: false, ...override });
    expect(Object.keys(body)).not.toContain("backend");
  });

  it("add the backend when it changes, null for the Mac's", () => {
    expect(modelSettingsSave(ON_MAC, { backend: "Claude Code", settings: ON_CLAUDE, selection: override }))
      .toEqual({ revision: "rev-1", usesDefaults: false, ...override, backend: "Claude Code" });
    expect(modelSettingsSave(ON_MAC, { backend: "Antigravity", settings: ON_ANTIGRAVITY, selection: null }))
      .toEqual({ revision: "rev-1", usesDefaults: true, backend: "Antigravity" });
    expect(modelSettingsSave(OWN_CLAUDE, { backend: "mac", settings: { ...ON_MAC, revision: "rev-2" }, selection: null }))
      .toEqual({ revision: "rev-2", usesDefaults: true, backend: null });
  });

  it("send only the backend when its models can't be chosen here", () => {
    expect(modelSettingsSave(OWN_CLAUDE, { backend: "mac", settings: OWN_CLAUDE_ON_MAC, selection: null }))
      .toEqual({ revision: "rev-2", backend: null });
  });
});

// MARK: The sheet's flow

describe("switching a tab's backend", () => {
  it("reads the other backend's settings and swaps the draft, then saves both with the tab's revision", async () => {
    serve(ON_MAC, { "Claude Code": ON_CLAUDE });
    const state = modelSettingsState(SESSION);
    await state.load(true);
    expect(calls().map((call) => call.url)).toEqual([`${PATH}?history=recent`]);
    expect(state.backend.value).toBe("mac");
    expect(state.backendChanged.value).toBe(false);

    await state.chooseBackend("Claude Code");
    expect(calls()[1]).toMatchObject({ url: `${PATH}?backend=Claude%20Code&history=recent`, method: "GET" });
    expect(state.backend.value).toBe("Claude Code");
    expect(state.backendChanged.value).toBe(true);
    expect(state.settings.value?.models.map((model) => model.id)).toEqual(["sample-claude-a", "sample-claude-b"]);
    expect(state.selection.value).toEqual({ model: "sample-claude-b", effort: "high", contextTier: "" });
    expect(state.usesDefaults.value).toBe(false);
    expect(state.saved.value?.revision).toBe("rev-1");
    expect(state.canSave.value).toBe(true);

    expect(await state.save()).toBe(true);
    // The check before writing reads the draft's backend.
    expect(calls()[2]).toMatchObject({ url: `${PATH}?backend=Claude%20Code&history=recent`, method: "GET" });
    expect(posted()).toEqual({ revision: "rev-1", usesDefaults: false, model: "sample-claude-b", effort: "high", contextTier: "", backend: "Claude Code" });
  });

  it("refreshes the models of the backend shown", async () => {
    serve(ON_MAC, { "Claude Code": ON_CLAUDE });
    const state = modelSettingsState(SESSION);
    await state.load(true);
    await state.chooseBackend("Claude Code");
    await state.load(false, true);
    expect(calls().at(-1)?.url).toBe(`${PATH}?backend=Claude%20Code&refresh=true&history=recent`);
    expect(state.selection.value.model).toBe("sample-claude-b");

    await state.load(true);
    await state.load(false, true);
    expect(calls().at(-1)?.url).toBe(`${PATH}?refresh=true&history=recent`);
  });

  it("keeps only the latest pick's reply, and none once the sheet closes", async () => {
    serve(ON_MAC, {});
    const state = modelSettingsState(SESSION);
    await state.load(true);

    const claude = held(ON_CLAUDE);
    fetchMock.mockImplementationOnce(() => claude.reply);
    const first = state.chooseBackend("Claude Code");
    fetchMock.mockImplementationOnce(() => answer(200, ON_ANTIGRAVITY));
    await state.chooseBackend("Antigravity");
    claude.release();
    await first;
    expect(state.backend.value).toBe("Antigravity");
    expect(state.settings.value?.backend).toBe("Antigravity");
    expect(state.selection.value.model).toBe("sample-gravity-a");
    expect(state.switching.value).toBe(false);

    const late = held(ON_CLAUDE);
    fetchMock.mockImplementationOnce(() => late.reply);
    const pending = state.chooseBackend("Claude Code");
    expect(state.canSave.value).toBe(false);
    state.close();
    late.release();
    await pending;
    expect(state.settings.value?.backend).toBe("Antigravity");
  });

  it("goes back to the shown backend when the Mac refuses the pick", async () => {
    serve(ON_MAC, {});
    const state = modelSettingsState(SESSION);
    await state.load(true);
    fetchMock.mockImplementationOnce(() => answer(400, { error: "Ask about Copilot, Claude Code, Codex, Antigravity or mac." }));
    await state.chooseBackend("Claude Code");
    expect(state.backend.value).toBe("mac");
    expect(state.settings.value?.backend).toBe("Copilot");
    expect(state.error.value).toBe("Ask about Copilot, Claude Code, Codex, Antigravity or mac.");
  });

  it("saves only the backend (null = the Mac's) when its models can't be chosen", async () => {
    serve(OWN_CLAUDE, { mac: OWN_CLAUDE_ON_MAC });
    const state = modelSettingsState(SESSION);
    await state.load(true);
    expect(state.backend.value).toBe("Claude Code");

    await state.chooseBackend("mac");
    expect(calls()[1].url).toBe(`${PATH}?backend=mac&history=recent`);
    expect(state.settings.value?.unavailableReason).toContain("no per-tab models");
    expect(state.validation.value).toBeNull();
    expect(state.canSave.value).toBe(true);

    expect(await state.save()).toBe(true);
    expect(posted()).toEqual({ revision: "rev-2", backend: null });
  });

  it("can't save a backend change while the tab can't change backend", async () => {
    const busy = "Wait for this tab and its queued work to finish before changing model settings.";
    serve(ON_MAC, { Antigravity: { ...ON_ANTIGRAVITY, backendUnavailableReason: busy, unavailableReason: busy } });
    const state = modelSettingsState(SESSION);
    await state.load(true);
    await state.chooseBackend("Antigravity");
    expect(state.canSave.value).toBe(false);
    expect(await state.save()).toBe(false);
    expect(calls().filter((call) => call.method === "POST")).toHaveLength(0);
  });

  it("saves exactly as before on Macs without tab backends", async () => {
    serve(OLDER_MAC, {});
    const state = modelSettingsState(SESSION);
    await state.load(true);
    expect(tabBackendChoices(state.settings.value)).toBeNull();
    expect(state.backendChanged.value).toBe(false);

    state.usesDefaults.value = true;
    expect(await state.save()).toBe(true);
    expect(calls().map((call) => call.url)).toEqual([`${PATH}?history=recent`, `${PATH}?history=recent`, `${PATH}?history=recent`]);
    expect(posted()).toEqual({ revision: "rev-0", usesDefaults: true });
  });
});
