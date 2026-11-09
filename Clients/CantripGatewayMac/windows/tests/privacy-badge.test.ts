import { describe, expect, it, vi } from "vitest";

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

import type { PrivacyBadge, RemoteMessage, RemoteSessionSummary } from "../src/gateway/api/types";
import { MessageRow } from "../src/gateway/ui/transcript/Message";
import { PrivacyBadgeLine, privacyBadgeView } from "../src/gateway/ui/transcript/PrivacyBadge";

// MARK: A small VNode walker (no DOM), as in thread-tags.test.ts.

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

/** Every VNode in a tree, in order, without calling components (prompt rows use hooks). */
function vnodes(value: unknown): VNode[] {
  if (Array.isArray(value)) return value.flatMap(vnodes);
  if (!isVNode(value)) return [];
  return [value, ...vnodes(value.props.children)];
}

// MARK: Fixtures (synthetic)

const SESSION = "5B1E2C7A-0F3D-4C1B-9A8E-2D6F7E8A9B0C";
const PROMPT = "3C9D8E7F-6A5B-4C3D-8E2F-1A0B9C8D7E6F";

function badge(overrides: Partial<PrivacyBadge> = {}): PrivacyBadge {
  return {
    route: "local", mode: "observe", applied: false, label: "Would run locally · secrets",
    detail: "Matched the secrets rule. Rules 2 ms, 2 ms in all. Observing: this run was sent as usual.", ...overrides,
  };
}

function message(overrides: Partial<RemoteMessage>): RemoteMessage {
  return { id: PROMPT, role: "user", text: "Summarize the sample notes", thinking: "", activities: [], isLocalPrivate: false, ...overrides };
}

const session = { id: SESSION, title: "Cantrip Home" } as unknown as RemoteSessionSummary;
const row = (value: RemoteMessage) => vnodes(MessageRow({ message: value, session, lane: "home", streaming: false, reported: new Set() }));
const named = (node: VNode, name: string) => (node.type as { name?: string }).name === name;

describe("privacy badges", () => {
  it("draws a glyph per route, quiet while observing and accent only when enforce mode keeps it local", () => {
    expect(privacyBadgeView(badge())).toMatchObject({ route: "local", icon: "lock.fill", tone: "secondary", accessibleName: "Privacy: Would run locally · secrets" });
    expect(privacyBadgeView(badge({ mode: "enforce", applied: true, label: "Ran locally · secrets" }))).toMatchObject({ icon: "lock.fill", tone: "accent" });
    expect(privacyBadgeView(badge({ route: "cloud", mode: "enforce", applied: true, label: "Cloud, no private tools · 92% cloud" })))
      .toMatchObject({ icon: "cloud.fill", tone: "secondary" });
    expect(privacyBadgeView(badge({ route: "redactApprove", label: "Would ask first · account number" }))).toMatchObject({ icon: "eye.slash", tone: "secondary" });
    expect(privacyBadgeView(badge({ route: "offline", mode: "enforce", label: "Held: privacy check offline · classifier offline" })))
      .toMatchObject({ icon: "shield.slash", tone: "secondary" });
  });

  it("falls back for a missing label or a newer route, and draws nothing without a badge", () => {
    expect(privacyBadgeView(badge({ route: "cloud", label: "  ", detail: "" }))).toMatchObject({ label: "Cloud", detail: "", accessibleName: "Privacy: Cloud" });
    expect(privacyBadgeView(badge({ route: "somewhereNew", label: "Somewhere new" }))).toMatchObject({ icon: "info.circle", label: "Somewhere new" });
    expect(privacyBadgeView(badge({ route: "somewhereNew", label: "" }))).toBeNull();
    expect(privacyBadgeView({ route: 3, label: 4 })).toBeNull();
    expect(privacyBadgeView(undefined)).toBeNull();
    expect(privacyBadgeView("local")).toBeNull();
  });

  it("names the badge \"Privacy: <label>\" and puts the reason in its tooltip", () => {
    const [node] = render(PrivacyBadgeLine({ privacy: badge({ mode: "enforce", applied: true, label: "Ran locally · secrets" }) })) as Element[];
    expect(node.tag).toBe("span");
    expect(node.props).toMatchObject({
      class: "privacy-badge tone-accent", role: "img", "data-route": "local", "aria-label": "Privacy: Ran locally · secrets",
      title: "Matched the secrets rule. Rules 2 ms, 2 ms in all. Observing: this run was sent as usual.",
    });
    expect(text([node])).toBe("Ran locally · secrets");
    expect(node.children.some((child) => typeof child !== "string" && child.tag === "svg")).toBe(true);

    const [quiet] = render(PrivacyBadgeLine({ privacy: badge({ detail: "" }) })) as Element[];
    expect(quiet.props.class).toBe("privacy-badge tone-secondary");
    expect(quiet.props.title).toBeUndefined();
    expect(render(PrivacyBadgeLine({ privacy: undefined }))).toEqual([]);
  });

  it("shows under a prompt once the Mac sends it, above its token usage, and never on replies", () => {
    expect(row(message({})).some((node) => node.type === PrivacyBadgeLine)).toBe(false);

    const usage = { modelCalls: 1, inputTokens: 1200, cachedInputTokens: 0, outputTokens: 80 };
    const nodes = row(message({ privacy: badge(), promptUsage: usage }));
    const at = nodes.findIndex((node) => node.type === PrivacyBadgeLine);
    expect(at).toBeGreaterThan(0);
    expect(nodes[at].props.privacy).toEqual(badge());
    expect(nodes.findIndex((node) => named(node, "PromptUsageLine"))).toBeGreaterThan(at);

    expect(row(message({ role: "assistant", text: "Done.", privacy: badge() })).some((node) => node.type === PrivacyBadgeLine)).toBe(false);
  });
});
