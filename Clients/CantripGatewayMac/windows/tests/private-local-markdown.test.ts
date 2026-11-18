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

import type { RemoteMessage, RemoteSessionSummary } from "../src/gateway/api/types";
import { MessageRow } from "../src/gateway/ui/transcript/Message";

// MARK: A small VNode walker (no DOM), as in privacy-badge.test.ts.

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

function elements(nodes: Node[]): Element[] {
  return nodes.flatMap((node) => (typeof node === "string" ? [] : [node, ...elements(node.children)]));
}

function text(nodes: Node[]): string {
  return nodes.map((node) => (typeof node === "string" ? node : text(node.children))).join("");
}

// MARK: Fixtures (synthetic)

const SESSION = "91A48C51-0000-4000-8000-00000000F00D";
const REPLY = [
  "## Plan", "", "**Bold** and *italic* with `inline code`.", "", "- one", "- two", "", "1. first", "2. second", "",
  "| Name | Value |", "| --- | --- |", "| alpha | 1 |", "", "```swift", "let x = 1", "```", "",
  "[Docs](https://example.com/docs)", "", "![Chart](https://example.com/chart.png)",
].join("\n");

function rowFor(privateLocal: boolean, streaming = false): Node[] {
  const session = { id: SESSION, title: "Private Local", isLocalPrivate: privateLocal } as unknown as RemoteSessionSummary;
  const message: RemoteMessage = { id: "A1", role: "assistant", text: REPLY, thinking: "", activities: [], isLocalPrivate: privateLocal };
  return render(MessageRow({ message, session, lane: "tab", streaming, reported: new Set() }));
}

describe("Private Local replies", () => {
  it("render Markdown like other tabs, while streaming and after", () => {
    const tags = (nodes: Node[]) => new Set(elements(nodes).map((node) => node.tag));
    const regular = tags(rowFor(false));
    for (const streaming of [true, false]) {
      const nodes = rowFor(true, streaming);
      for (const tag of ["h2", "strong", "em", "code", "ul", "ol", "li", "table", "td", "pre", "a"]) {
        expect(tags(nodes).has(tag), `${tag} while streaming=${streaming}`).toBe(true);
        expect(regular.has(tag)).toBe(true);
      }
      expect(text(nodes)).not.toContain("**Bold**");
      expect(elements(nodes).some((node) => String(node.props.class ?? "").includes("private-text"))).toBe(false);
    }
  });

  it("never load an image: the description shows instead", () => {
    const nodes = elements(rowFor(true));
    expect(nodes.some((node) => node.tag === "img")).toBe(false);
    expect(text(nodes.filter((node) => node.props.class === "image-unavailable"))).toBe("Image not loaded: Chart");
    expect(elements(rowFor(false)).some((node) => node.tag === "img" && node.props.src === "https://example.com/chart.png")).toBe(true);
  });
});
