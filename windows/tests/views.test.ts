import { readFileSync } from "node:fs";
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import { HomeService, homeReadPath, homeWriteRequest } from "../src/main/home/service";
import type { SendWithToken } from "../src/main/home/service";
import type { Pairing, PairingStore } from "../src/main/home/store";
import { sendOverHTTPS } from "../src/main/home/transport";
import type { HostRequest, HostResponse } from "../src/main/home/transport";
import { cardElement, cardLayout, linePoints, pieSlices, tableModel, type ButtonModel, type CardNode } from "../src/renderer/cards";
import type { Block, CardDocument } from "../src/shared/cards";
import { cardPlainText } from "../src/shared/cards";
import { HOME_WINDOW_ACTION_KINDS, parseView, parseViews, viewActionIDs } from "../src/shared/views";

const TOKEN = "test-pairing-token-0123456789abcdefghijk";
const LINK = `cantripagent://pair?v=1&name=Studio&token=${TOKEN}&url=https://mac.example.com&direct=10.0.0.0:8766`;
const VIEW_ID = "7F3B2C1A-1111-4222-8333-944455556666";

const card = (blocks: Block[], extra: Partial<CardDocument> = {}): CardDocument =>
  ({ version: 1, id: `view-${VIEW_ID}`, type: "view", source: { kind: "view", name: "Homelab" }, blocks, ...extra });
const VIEW_CARD = card([
  { type: "header", title: "Homelab" },
  { type: "actions", buttons: [
    { id: "refresh-1", kind: "refresh", label: "Refresh", confirmTitle: "Refresh Homelab?", confirmMessage: "Reads the view's sources again." },
    { id: "open-1", kind: "open", label: "Open dashboard", style: "prominent", confirmTitle: "Open the dashboard?" },
    { id: "run-1", kind: "runTask", label: "Run now", confirmTitle: "Run it?" },
  ] },
]);
const VIEW = { id: VIEW_ID, name: "Homelab", pinned: true, private: false, sources: ["tool"], updatedAt: "2026-11-17T20:00:00Z" };

function json(status: number, value: unknown): HostResponse {
  return { status, headers: { "content-type": "application/json" }, body: Buffer.from(JSON.stringify(value)) };
}

/** A pairing kept in memory (the real store writes an encrypted file). */
function memoryStore(): PairingStore {
  let saved: Pairing | null = null;
  return {
    load: () => saved,
    save: (server: Pairing["server"], token: string) => (saved = { server, token }),
    clear: () => { saved = null; },
  } as unknown as PairingStore;
}

async function pairedService(answer: (request: HostRequest) => HostResponse) {
  const seen: HostRequest[] = [];
  const send: SendWithToken = async (_route, _token, request) => {
    seen.push(request);
    return request.path === "/api/v1/home/background" ? json(200, { sessionID: "", runs: [], queued: [] }) : answer(request);
  };
  const service = new HomeService(memoryStore(), send);
  expect(await service.pair(LINK)).toMatchObject({ ok: true });
  seen.length = 0;
  return { service, seen };
}

describe("views in the read-only Home window: the main process", () => {
  it("reads the views list and a view, and refuses bad IDs", () => {
    expect(homeReadPath({ kind: "views" }, null)).toBe("/api/v1/home/views");
    expect(homeReadPath({ kind: "views", revision: "r1+2" }, null)).toBe("/api/v1/home/views?revision=r1%2B2");
    expect(homeReadPath({ kind: "view", viewID: VIEW_ID }, null)).toBe(`/api/v1/home/views/${VIEW_ID}`);
    for (const viewID of ["../tasks", "a/b", "", "?x=1", 7, "x".repeat(200)]) {
      expect(() => homeReadPath({ kind: "view", viewID }, null)).toThrow();
    }
    expect(() => homeReadPath({ kind: "views", revision: "a\nb" }, null)).toThrow();
  });

  it("builds only a view's Refresh and the buttons it was sent, always confirmed", () => {
    const allowed = new Set(["refresh-1", "open-1"]);
    const lookup = (viewID: string) => (viewID === VIEW_ID ? allowed : undefined);
    expect(homeWriteRequest({ kind: "refresh", viewID: VIEW_ID }, lookup)).toEqual({ path: `/api/v1/home/views/${VIEW_ID}/refresh` });
    expect(homeWriteRequest({ kind: "action", viewID: VIEW_ID, actionID: "open-1" }, lookup))
      .toEqual({ path: `/api/v1/home/views/${VIEW_ID}/actions/open-1`, body: { confirmed: true } });
    expect(() => homeWriteRequest({ kind: "action", viewID: VIEW_ID, actionID: "run-1" }, lookup)).toThrow(/can't run/);
    expect(() => homeWriteRequest({ kind: "action", viewID: "OTHER", actionID: "open-1" }, lookup)).toThrow();
    expect(() => homeWriteRequest({ kind: "delete", viewID: VIEW_ID }, lookup)).toThrow();
    expect(() => homeWriteRequest({ kind: "pin", viewID: VIEW_ID }, lookup)).toThrow();
  });

  it("posts only refresh and link buttons the Mac sent for that view, with {confirmed: true}", async () => {
    const { service, seen } = await pairedService((request) =>
      request.method === "GET" ? json(200, { view: VIEW, card: VIEW_CARD, refreshAfter: 30 })
        : request.path.endsWith("/refresh") ? json(200, { view: VIEW, card: VIEW_CARD })
          : json(200, { result: "open", url: "https://dashboard.example.com" }));
    // Before the view was read, no button is known.
    expect(await service.viewWrite({ kind: "action", viewID: VIEW_ID, actionID: "refresh-1" })).toMatchObject({ ok: false });
    expect(seen).toHaveLength(0);

    expect(await service.read({ kind: "view", viewID: VIEW_ID })).toMatchObject({ ok: true });
    expect(await service.viewWrite({ kind: "action", viewID: VIEW_ID, actionID: "run-1" })).toMatchObject({ ok: false });
    expect(seen).toHaveLength(1);

    expect(await service.viewWrite({ kind: "action", viewID: VIEW_ID, actionID: "open-1" }))
      .toEqual({ ok: true, data: { result: "open", url: "https://dashboard.example.com" } });
    const post = seen.at(-1)!;
    expect(post).toMatchObject({ method: "POST", path: `/api/v1/home/views/${VIEW_ID}/actions/open-1` });
    expect(post.headers).toMatchObject({ authorization: `Bearer ${TOKEN}`, "content-type": "application/json" });
    expect(JSON.parse(post.body!.toString("utf8"))).toEqual({ confirmed: true });

    expect(await service.viewWrite({ kind: "refresh", viewID: VIEW_ID })).toMatchObject({ ok: true });
    expect(seen.at(-1)).toMatchObject({ method: "POST", path: `/api/v1/home/views/${VIEW_ID}/refresh` });
  });

  it("sends a POST body over the HTTPS route", async () => {
    const fetchImpl = vi.fn(async () => new Response("{}", { status: 200 }));
    await sendOverHTTPS("https://mac.example.com", {
      method: "POST", path: "/api/v1/home/views/V/actions/a", headers: { "content-type": "application/json" }, body: Buffer.from('{"confirmed":true}'),
    }, fetchImpl);
    const [url, init] = fetchImpl.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe("https://mac.example.com/api/v1/home/views/V/actions/a");
    expect(init.method).toBe("POST");
    expect(Buffer.from(init.body as Uint8Array).toString()).toBe('{"confirmed":true}');
  });

  it("reads the Mac's answers leniently and keeps only refresh and open buttons", () => {
    expect(viewActionIDs(VIEW_CARD)).toEqual(["refresh-1", "open-1"]);
    expect(viewActionIDs(VIEW_CARD, new Set(["runTask"]))).toEqual(["run-1"]);
    const list = parseViews({ revision: "r1", views: [{ ...VIEW, pinned: false, id: "A" }, VIEW, { name: "no id" }] });
    expect(list && !list.unchanged ? list.views.map((view) => view.id) : null).toEqual([VIEW_ID, "A"]);
    expect(parseViews({ unchanged: true, revision: "r1" })).toEqual({ unchanged: true, revision: "r1" });
    expect(parseView({ view: VIEW, card: VIEW_CARD, refreshAfter: 30 })?.refreshMs).toBe(30_000);
    expect(parseView({ view: VIEW })).toBeNull();
  });
});

// Real host output: views the Mac's resolver built from live homelab status and tracker record counts.
const fixture = (name: string) => JSON.parse(readFileSync(new URL(`./views/${name}.json`, import.meta.url), "utf8"));

describe("views from the Mac", () => {
  it("shows the This week view's tabs and hides its run and ask buttons in this window", () => {
    const shown = parseView(fixture("view-dashboard"))!;
    expect(shown.refreshMs).toBe(30_000);
    expect(viewActionIDs(shown.card)).toEqual([]);
    const nodes = cardLayout(shown.card, HOME_WINDOW_ACTION_KINDS);
    expect(nodes.map((node) => node.kind === "tabs" ? node.tabs.map((tab) => `${tab.title}:${tab.nodes.length}`).join(",") : node.block.type))
      .toEqual(["header", "Overview:3,Interviews:2,Bills:1"]);
    expect(cardPlainText(shown.card)).toBe(shown.card.fallbackText);
  });

  it("lets this window post only the Homelab view's Refresh button", () => {
    const shown = parseView(fixture("view-homelab"))!;
    expect(viewActionIDs(shown.card)).toEqual(["a1"]);
    expect(cardLayout(shown.card, HOME_WINDOW_ACTION_KINDS).map((node) => (node as { block: Block }).block.type))
      .toEqual(["header", "stat", "section", "table", "keyValue", "actions"]);
    expect(cardPlainText(shown.card)).toBe(shown.card.fallbackText);
    const list = parseViews(fixture("views-list"));
    expect(list && !list.unchanged ? list.views.map((view) => [view.name, view.private]) : null).toEqual([["Homelab", true], ["This week", false]]);
  });
});

describe("view card blocks: layout", () => {
  const stat = (label: string): Block => ({ type: "stat", label, value: "1" });
  const kinds = (nodes: CardNode[]) => nodes.map((node) => (node.kind === "tabs" ? "tabs" : node.block.type));

  it("gives each tab the next `count` blocks, counting skipped blocks and clamping past the end", () => {
    const nodes = cardLayout(card([
      { type: "tabs", tabs: [{ title: "Jobs", count: 2 }, { title: "Bills", count: 9 }] },
      stat("Applied"), { type: "map" }, stat("Due"), { type: "notice", title: "Last" },
    ]));
    expect(kinds(nodes)).toEqual(["tabs"]);
    const tabs = nodes[0] as Extract<CardNode, { kind: "tabs" }>;
    expect(tabs.tabs.map((tab) => tab.nodes.map((node) => (node as { block: Block }).block.label ?? (node as { block: Block }).block.title)))
      .toEqual([["Applied"], ["Due", "Last"]]);
  });

  it("shows actions only on a view's card, with only the kinds this window runs", () => {
    expect(kinds(cardLayout(VIEW_CARD))).toEqual(["header"]);
    expect(kinds(cardLayout(VIEW_CARD, HOME_WINDOW_ACTION_KINDS))).toEqual(["header", "actions"]);
    expect(kinds(cardLayout(card([{ type: "actions", buttons: [{ id: "x", kind: "ask", label: "Ask" }] }]), HOME_WINDOW_ACTION_KINDS))).toEqual([]);
  });

  it("works out tables, line points and pie shares", () => {
    const table = tableModel({ type: "table", columns: [{ title: "Service" }, { title: "Up", align: "trailing" }],
      tableRows: [{ cells: [{ text: "Grafana" }, { text: "Yes", tone: "positive" }] }, { cells: [{ text: "Router" }], accessibilityLabel: "Router, unknown" }] })!;
    expect(table.rows.map((row) => [row.label, row.cells.map((cell) => `${cell.text}/${cell.tone}`)]))
      .toEqual([["Service: Grafana, Up: Yes", ["Grafana/", "Yes/tone-positive"]], ["Router, unknown", ["Router/", "/"]]]);
    const line = linePoints({ type: "chart", kind: "line", min: 0, max: 4, items: [{ label: "Mon", high: 0 }, { label: "Tue", high: 2 }, { label: "Wed", high: 4 }] });
    expect(line.points.map((point) => [point.x, point.y])).toEqual([[0, 100], [50, 50], [100, 0]]);
    expect(line.labelled).toEqual([0, 1, 2]);
    expect(linePoints({ type: "chart", kind: "line", min: 0, max: 2, items: [{ label: "A", high: 4 }, { label: "B", high: 1 }] }).max).toBe(4);
    const pie = pieSlices({ type: "chart", kind: "pie", items: [{ label: "A", high: 1 }, { label: "Zero", high: 0 }, { label: "B", high: 3, tone: "negative" },
      { label: "C", high: 4 }] });
    expect(pie.map((slice) => [slice.label, slice.percent, slice.color, slice.start]))
      .toEqual([["A", "13%", "#4C9DFF", 0], ["B", "38%", "#f87171", 0.125], ["C", "50%", "#AF52DE", 0.5]]);
  });

  it("writes the Mac's plain text for sections, tables and chart titles", () => {
    expect(cardPlainText({ blocks: [
      { type: "section", title: "Services", subtitle: "homelab" },
      { type: "table", title: "Status", columns: [{ title: "Service" }, { title: "Up" }], tableRows: [{ cells: [{ text: "Grafana" }, { text: "Yes" }] }] },
      { type: "chart", kind: "pie", title: "Stages", items: [{ label: "Applied", highText: "3" }] },
      { type: "actions", buttons: [{ id: "a", kind: "refresh", label: "Refresh" }] },
    ] })).toBe("SERVICES — HOMELAB\nStatus\nService | Up\nGrafana | Yes\nStages\nApplied 3");
  });
});

// MARK: A small fake DOM: enough of document for cards.ts (elements, attributes, text, classes, clicks).

class FakeElement {
  children: (FakeElement | FakeText)[] = [];
  attributes = new Map<string, string>();
  listeners = new Map<string, ((event: unknown) => unknown)[]>();
  style: Record<string, string> = {};
  dataset: Record<string, string> = {};
  className = "";
  hidden = false;
  disabled = false;
  tabIndex = -1;
  type = "";
  id = "";
  title = "";
  innerHTML = "";
  constructor(readonly tagName: string) {}
  get classList() {
    const names = () => new Set(this.className.split(/\s+/).filter(Boolean));
    return {
      add: (name: string) => { this.className = [...names().add(name)].join(" "); },
      remove: (name: string) => { const set = names(); set.delete(name); this.className = [...set].join(" "); },
      toggle: (name: string, on: boolean) => { const set = names(); if (on) set.add(name); else set.delete(name); this.className = [...set].join(" "); },
      contains: (name: string) => names().has(name),
    };
  }
  get textContent(): string { return this.children.map((child) => child.textContent).join(""); }
  set textContent(value: string) { this.children = value ? [new FakeText(value)] : []; }
  get childElementCount(): number { return this.children.filter((child) => child instanceof FakeElement).length; }
  get isConnected(): boolean { return false; }
  append(...nodes: (FakeElement | FakeText | string)[]): void {
    for (const node of nodes) this.children.push(typeof node === "string" ? new FakeText(node) : node);
  }
  replaceChildren(...nodes: FakeElement[]): void { this.children = []; this.append(...nodes); }
  setAttribute(name: string, value: string): void { this.attributes.set(name, String(value)); }
  getAttribute(name: string): string | null { return this.attributes.get(name) ?? null; }
  removeAttribute(name: string): void { this.attributes.delete(name); }
  addEventListener(type: string, listener: (event: unknown) => unknown): void {
    this.listeners.set(type, [...(this.listeners.get(type) ?? []), listener]);
  }
  focus(): void {}
  async click(): Promise<void> { await Promise.all((this.listeners.get("click") ?? []).map((listener) => listener({}))); }
  all(): FakeElement[] {
    return this.children.flatMap((child) => (child instanceof FakeElement ? [child, ...child.all()] : []));
  }
}

class FakeText {
  constructor(readonly textContent: string) {}
}

describe("view card blocks: drawn", () => {
  const scope = globalThis as Record<string, unknown>;
  const original = scope.document;
  beforeAll(() => {
    scope.document = {
      createElement: (tag: string) => new FakeElement(tag),
      createElementNS: (_ns: string, tag: string) => new FakeElement(tag),
      createTextNode: (text: string) => new FakeText(text),
    };
  });
  afterAll(() => { scope.document = original; });

  const draw = (document: CardDocument, options = {}) => cardElement(document, () => {}, options) as unknown as FakeElement;
  const byRole = (root: FakeElement, role: string) => root.all().filter((node) => node.getAttribute("role") === role);

  it("draws a table with column headers, row labels and a scrolling region", () => {
    const root = draw(card([{ type: "table", title: "Services", columns: [{ title: "Service" }, { title: "Up", align: "trailing" }],
      tableRows: [{ cells: [{ text: "Grafana" }, { text: "Yes", tone: "positive" }], accessibilityLabel: "Grafana is up" }] }]));
    const region = byRole(root, "region")[0];
    expect(region.getAttribute("aria-label")).toBe("Services");
    expect(region.tabIndex).toBe(0);
    const headers = root.all().filter((node) => node.tagName === "th");
    expect(headers.map((th) => [th.getAttribute("scope"), th.textContent])).toEqual([["col", "Service"], ["col", "Up"]]);
    const row = root.all().find((node) => node.tagName === "tr" && node.getAttribute("aria-label"))!;
    expect(row.getAttribute("aria-label")).toBe("Grafana is up");
    expect(row.children.map((td) => (td as FakeElement).className)).toEqual(["align-leading", "align-trailing tone-positive"]);
  });

  it("draws tabs as a tablist and shows only the selected tab's blocks", async () => {
    const root = draw(card([{ type: "tabs", tabs: [{ title: "Week", count: 1 }, { title: "Month", count: 1 }] },
      { type: "stat", label: "This week", value: "3" }, { type: "stat", label: "This month", value: "12" }], { id: "view-tabs-test" }));
    expect(byRole(root, "tablist")).toHaveLength(1);
    const tabs = byRole(root, "tab");
    const panels = byRole(root, "tabpanel");
    expect(tabs.map((tab) => [tab.textContent, tab.getAttribute("aria-selected"), tab.tabIndex])).toEqual([["Week", "true", 0], ["Month", "false", -1]]);
    expect(panels.map((panel) => [panel.hidden, panel.textContent])).toEqual([[false, "This week3"], [true, "This month12"]]);
    expect(tabs[1].getAttribute("aria-controls")).toBe(panels[1].id);
    await tabs[1].click();
    expect(panels.map((panel) => panel.hidden)).toEqual([true, false]);
    expect(tabs.map((tab) => tab.getAttribute("aria-selected"))).toEqual(["false", "true"]);
    // A redraw (the window's next poll) keeps the tab.
    expect(byRole(draw(card([{ type: "tabs", tabs: [{ title: "Week", count: 1 }, { title: "Month", count: 1 }] }, { type: "stat", label: "W", value: "1" },
      { type: "stat", label: "M", value: "2" }], { id: "view-tabs-test" })), "tabpanel").map((panel) => panel.hidden)).toEqual([true, false]);
  });

  it("asks before running a view's button, runs it only when confirmed, and hides kinds the window doesn't run", async () => {
    const confirm = vi.fn();
    const onAction = vi.fn(async (_button: ButtonModel) => {});
    expect(draw(VIEW_CARD).all().filter((node) => node.tagName === "button")).toEqual([]);
    const root = draw(VIEW_CARD, { onAction, confirm, actionKinds: HOME_WINDOW_ACTION_KINDS });
    const buttons = root.all().filter((node) => node.tagName === "button");
    expect(buttons.map((button) => [button.textContent, button.className])).toEqual([
      ["Refresh", "card-view-action"], ["Open dashboard", "card-view-action prominent"],
    ]);
    confirm.mockResolvedValueOnce(false);
    await buttons[0].click();
    expect(confirm).toHaveBeenCalledWith({ title: "Refresh Homelab?", message: "Reads the view's sources again.", confirm: "Refresh" });
    expect(onAction).not.toHaveBeenCalled();
    confirm.mockResolvedValueOnce(true);
    await buttons[1].click();
    expect(onAction).toHaveBeenCalledTimes(1);
    expect(onAction.mock.calls[0][0]).toMatchObject({ id: "open-1", kind: "open" });
  });

  it("draws a pie's legend with each share and a line's points as labelled stops", () => {
    const root = draw(card([
      { type: "chart", kind: "pie", title: "Stages", items: [{ label: "Applied", high: 3, highText: "3" }, { label: "Onsite", high: 1, highText: "1" }] },
      { type: "chart", kind: "line", min: 0, max: 4, items: [{ label: "Mon", high: 1, highText: "1" }, { label: "Tue", high: 4, highText: "4" }] },
    ]));
    expect(root.all().filter((node) => node.className === "card-pie-row").map((row) => row.getAttribute("aria-label")))
      .toEqual(["Applied, 3, 75%", "Onsite, 1, 25%"]);
    expect(root.all().filter((node) => node.className === "card-linechart-dot").map((dot) => [dot.getAttribute("aria-label"), dot.tabIndex]))
      .toEqual([["Mon, 1", 0], ["Tue, 4", 0]]);
  });
});
