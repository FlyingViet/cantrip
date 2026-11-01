import { describe, expect, it, vi } from "vitest";

// The sheets touch the page and the preload bridge when they load.
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

import type { CopilotUsageSnapshot, UsageFallbackRequest, UsageFallbackSnapshot } from "../src/gateway/api/types";
import { UsageFallbackEditor, type FallbackFocus } from "../src/gateway/ui/sheets/ModelSettingsSheet";
import { AntigravitySection, ClaudeSection, CodexSection } from "../src/gateway/ui/sheets/UsageSheet";

// MARK: A small VNode walker (no DOM): components are called with their props, like a shallow render.

interface VNode { type: unknown; props: Record<string, unknown> & { children?: unknown } }
interface Element { tag: string; props: Record<string, unknown>; children: Node[] }
type Node = Element | string;

function isVNode(value: unknown): value is VNode {
  return typeof value === "object" && value !== null && "type" in value && "props" in value;
}

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

function labelled(nodes: Node[], label: string): Element {
  const found = elements(nodes).find((node) => node.props["aria-label"] === label);
  if (!found) throw new Error(`No control labelled "${label}"`);
  return found;
}

function labels(nodes: Node[]): string[] {
  return elements(nodes).flatMap((node) => (typeof node.props["aria-label"] === "string" ? [node.props["aria-label"] as string] : []));
}

function options(select: Element): string[] {
  return select.children.flatMap((node) => (typeof node === "string" ? [] : [text(node.children)]));
}

// MARK: Usage limit fallbacks

// GET /api/v1/usage-fallback with Antigravity, the Mac's own backend, listed twice with other models.
const PER_MODEL: UsageFallbackSnapshot = {
  backends: ["Antigravity", "Antigravity", "Claude Code"],
  entries: [
    { backend: "Antigravity", model: "gemini-3.8-flash-medium", effort: "", label: "Antigravity · Gemini 3.8 Flash (Medium)",
      limitedUntil: "2026-11-01T03:00:00Z", limitedUntilLabel: "8:00 PM" },
    { backend: "Antigravity", model: "claude-sonnet-5-5-low", effort: "", label: "Antigravity · Claude Sonnet 5.5 (Low)" },
    { backend: "Claude Code", model: "claude-sonnet-5-5", effort: "high", label: "Claude Code · claude-sonnet-5-5 · high" },
  ],
  backend: "Antigravity",
  primary: "Antigravity",
  choices: [
    { id: "Claude Code", label: "Claude Code · opus", defaultEfforts: ["low", "high"], defaultModel: "opus", defaultModelID: "opus",
      models: [{ id: "claude-opus-5-5", label: "claude-opus-5-5", efforts: ["low", "high"] },
        { id: "claude-sonnet-5-5", label: "claude-sonnet-5-5", efforts: ["low", "medium", "high"] }] },
    { id: "Copilot", label: "Copilot" },
  ],
  primaryChoice: {
    id: "Antigravity", label: "Antigravity", defaultModel: "Gemini 4 Argon (High)", defaultModelID: "gemini-4-argon-high",
    models: [{ id: "gemini-3.8-flash-medium", label: "Gemini 3.8 Flash (Medium)", efforts: [] },
      { id: "claude-sonnet-5-5-low", label: "Claude Sonnet 5.5 (Low)", efforts: [] },
      { id: "gemini-4-argon-high", label: "Gemini 4 Argon (High)", efforts: [] },
      { id: "gemini-3.8-pro-high", label: "Gemini 3.8 Pro (High)", efforts: [] }],
  },
  limited: [],
  limitedModels: [{ backend: "Antigravity", scope: "argon", label: "Gemini 4 Argon", until: "2026-11-01T03:00:00Z", untilLabel: "8:00 PM" }],
  revision: "r7",
};

function editor(value: UsageFallbackSnapshot) {
  const saves: { change: UsageFallbackRequest | null; focus: FallbackFocus }[] = [];
  const nodes = render(UsageFallbackEditor({ value, saving: false, error: null, ids: "fb", onSave: (change, focus) => saves.push({ change, focus }) }));
  return { nodes, saves };
}

describe("usage limit fallback editor", () => {
  it("lists each backup by position with its label, limit and numbered controls", () => {
    const { nodes } = editor(PER_MODEL);
    const shown = text(nodes);
    expect(shown).toContain("1. Antigravity · Gemini 3.8 Flash (Medium)at its limit until 8:00 PM");
    expect(shown).toContain("2. Antigravity · Claude Sonnet 5.5 (Low)");
    expect(shown).toContain("3. Claude Code · claude-sonnet-5-5 · high");
    expect(shown).toContain("At its usage limit: Antigravity Gemini 4 Argon until 8:00 PM.");
    expect(labels(nodes)).toEqual([
      "Try Antigravity backup 1 earlier", "Try Antigravity backup 1 later", "Remove Antigravity backup 1", "Antigravity backup 1 model",
      "Try Antigravity backup 2 earlier", "Try Antigravity backup 2 later", "Remove Antigravity backup 2", "Antigravity backup 2 model",
      "Try Claude Code backup 3 earlier", "Try Claude Code backup 3 later", "Remove Claude Code backup 3", "Claude Code backup 3 model",
      "Claude Code backup 3 effort",
    ]);
    expect(labelled(nodes, "Try Antigravity backup 1 earlier").props.disabled).toBe(true);
    expect(labelled(nodes, "Try Claude Code backup 3 later").props.disabled).toBe(true);
    expect(labelled(nodes, "Remove Antigravity backup 2").props["aria-describedby"]).toBe("fb-backup1-name");
  });

  it("leaves models another backup on the backend runs out of each picker", () => {
    const { nodes } = editor(PER_MODEL);
    expect(options(labelled(nodes, "Antigravity backup 1 model"))).toEqual(["Gemini 3.8 Flash (Medium)", "Gemini 3.8 Pro (High)"]);
    expect(options(labelled(nodes, "Antigravity backup 2 model"))).toEqual(["Claude Sonnet 5.5 (Low)", "Gemini 3.8 Pro (High)"]);
    expect(options(labelled(nodes, "Claude Code backup 3 model"))).toEqual(["Default (opus)", "claude-opus-5-5", "claude-sonnet-5-5"]);
    expect(options(labelled(nodes, "Claude Code backup 3 effort"))).toEqual(["Default effort", "low", "medium", "high"]);
    const add = elements(nodes).find((node) => node.props.id === "fb-add");
    expect(add && options(add)).toEqual(["Choose a backend…", "Claude Code with another model", "Copilot", "Antigravity with another model"]);
    expect(text(nodes)).toContain("Try every backend again");
  });

  it("saves the whole chain as entries for the row that changed, and keeps focus on a moved backup", () => {
    const { nodes, saves } = editor(PER_MODEL);
    const [first, second, third] = PER_MODEL.entries!.map(({ backend, model, effort }) => ({ backend, model, effort }));
    (labelled(nodes, "Try Antigravity backup 2 earlier").props.onClick as () => void)();
    expect(saves.at(-1)).toEqual({ change: { revision: "r7", entries: [second, first, third] },
      focus: { saved: ["fb-backup0-up", "fb-backup0-down"], failed: ["fb-backup1-up", "fb-backup1-down"] } });
    (labelled(nodes, "Try Antigravity backup 2 later").props.onClick as () => void)();
    expect(saves.at(-1)?.change).toEqual({ revision: "r7", entries: [first, third, second] });
    expect(saves.at(-1)?.focus.saved).toEqual(["fb-backup2-down", "fb-backup2-up"]);
    (labelled(nodes, "Remove Antigravity backup 1").props.onClick as () => void)();
    expect(saves.at(-1)?.change).toEqual({ revision: "r7", entries: [second, third] });
    (labelled(nodes, "Antigravity backup 2 model").props.onChange as (event: unknown) => void)({ currentTarget: { value: "gemini-3.8-pro-high" } });
    expect(saves.at(-1)?.change).toEqual({ revision: "r7", entries: [first, { ...second, model: "gemini-3.8-pro-high" }, third] });
    (labelled(nodes, "Claude Code backup 3 effort").props.onChange as (event: unknown) => void)({ currentTarget: { value: "low" } });
    expect(saves.at(-1)?.change).toEqual({ revision: "r7", entries: [first, second, { ...third, effort: "low" }] });
    const add = elements(nodes).find((node) => node.props.id === "fb-add")!;
    (add.props.onChange as (event: unknown) => void)({ currentTarget: { value: "Antigravity" } });
    expect(saves.at(-1)?.change).toEqual({ revision: "r7", entries: [first, second, third,
      { backend: "Antigravity", model: "gemini-3.8-pro-high", effort: "" }] });
  });

  it("saves `backends` for a Mac without entries, with no model pickers", () => {
    const older: UsageFallbackSnapshot = {
      backend: "Copilot", backends: ["Copilot", "Codex"], primary: "Claude Code", revision: "f1",
      choices: [{ id: "Copilot", label: "Copilot" }, { id: "Codex", label: "Codex" }, { id: "Antigravity", label: "Antigravity" }],
      limited: [{ backend: "Claude Code", until: "2026-10-28T12:00:00Z", untilLabel: "5:00 AM" }],
    };
    const { nodes, saves } = editor(older);
    expect(labels(nodes).filter((label) => label.endsWith("model"))).toEqual([]);
    (labelled(nodes, "Try Codex backup 2 earlier").props.onClick as () => void)();
    expect(saves.at(-1)?.change).toEqual({ revision: "f1", backends: ["Codex", "Copilot"] });
    const add = elements(nodes).find((node) => node.props.id === "fb-add")!;
    expect(options(add)).toEqual(["Choose a backend…", "Antigravity"]);
    expect(text(nodes)).toContain("Try every backend again");
  });
});

// MARK: Usage Limits

describe("usage limits per model", () => {
  const now = Date.parse("2026-10-31T20:00:00Z");
  // GET /api/v1/copilot/usage with each backend's per-model limits.
  const usage = JSON.parse(`{
    "isRefreshing": false,
    "claude": {"checkedAt": "2026-10-31T19:58:00Z", "account": {"windows": [
      {"id": "five_hour", "percentUsed": 12, "resetsAt": "2026-10-31T23:00:00Z"},
      {"id": "seven_day", "percentUsed": 40, "resetsAt": "2026-11-04T00:00:00Z"},
      {"id": "seven_day_opus", "percentUsed": 100, "resetsAt": "2026-11-04T00:00:00Z"},
      {"id": "seven_day_sonnet", "percentUsed": 55, "resetsAt": "2026-11-04T00:00:00Z"}]}},
    "antigravity": {"checkedAt": "2026-10-31T19:58:00Z", "account": {"groups": [
      {"name": "Gemini models", "models": "Gemini Flash, Gemini Pro", "buckets": [
        {"id": "gemini-weekly", "name": "Weekly Limit Remaining", "window": "weekly", "remainingPercent": 60, "resetsAt": "2026-11-04T00:00:00Z"},
        {"id": "gemini-5h", "name": "Five Hour Limit Remaining", "window": "5h", "remainingPercent": 90, "resetsAt": "2026-10-31T23:00:00Z"}]},
      {"name": "Gemini 4 Argon", "buckets": [
        {"id": "argon-5h", "name": "Five Hour Limit Remaining", "window": "5h", "remainingPercent": 0, "resetsAt": "2026-11-01T03:00:00Z"}]},
      {"name": "Claude and GPT models", "buckets": [
        {"id": "claude-gpt-weekly", "name": "Weekly Limit Remaining", "window": "weekly", "remainingPercent": 75, "resetsAt": "2026-11-04T00:00:00Z"}]}]}},
    "codex": {"checkedAt": "2026-10-31T19:58:00Z", "account": {"plan": "plus", "windows": [
      {"id": "codex/primary", "usedPercent": 20, "windowMinutes": 300, "resetsAt": "2026-10-31T23:00:00Z"},
      {"id": "codex/secondary", "usedPercent": 50, "windowMinutes": 10080, "resetsAt": "2026-11-04T00:00:00Z"},
      {"id": "gpt-6-luna/primary", "usedPercent": 100, "windowMinutes": 300, "resetsAt": "2026-10-31T23:00:00Z", "limitName": "GPT-6 Luna"}]}}
  }`) as CopilotUsageSnapshot;

  const headlines = (nodes: Node[]) =>
    elements(nodes).filter((node) => node.props.class === "headline").map((node) => text(node.children));
  const headers = (nodes: Node[]) =>
    elements(nodes).filter((node) => node.props.class === "form-header").map((node) => text(node.children));

  it("shows Claude's weekly Opus and Sonnet limits", () => {
    const nodes = render(ClaudeSection({ state: usage.claude!, now }));
    expect(headlines(nodes)).toEqual(["5-hour session · 12% used", "Weekly limit · 40% used", "Weekly Opus limit · 100% used", "Weekly Sonnet limit · 55% used"]);
  });

  it("shows each Antigravity model group with its buckets", () => {
    const nodes = render(AntigravitySection({ state: usage.antigravity!, now }));
    expect(headers(nodes)).toEqual(["Antigravity · Gemini models", "Antigravity · Gemini 4 Argon", "Antigravity · Claude and GPT models"]);
    expect(headlines(nodes)).toEqual(["Weekly limit · 40% used", "5-hour limit · 10% used", "5-hour limit · 100% used", "Weekly limit · 25% used"]);
  });

  it("shows Codex's windows, a model's own by its limit name", () => {
    const nodes = render(CodexSection({ state: usage.codex!, now }));
    expect(headers(nodes)).toEqual(["Codex · ChatGPT Plus"]);
    expect(headlines(nodes)).toEqual(["5-hour limit · 20% used", "Weekly limit · 50% used", "GPT-6 Luna 5-hour limit · 100% used"]);
  });
});
